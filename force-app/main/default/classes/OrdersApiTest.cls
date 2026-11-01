/** The callout layer: client error mapping, enrichment job and the live-read controller. */
@IsTest
private class OrdersApiTest {
  private static final String ACCOUNT_JSON = '{"id":"acct_8f3c2a","friendlyId":"AC-260914-017-2231","name":"Northwind Plan Sponsor LLC","status":"active","updatedAt":"2026-10-12T14:03:11Z"}';
  private static final String ORDER_JSON = '{"id":"ord_77d1e9","friendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","participantRef":"p_4411","status":"sent","amount":{"value":"1250.00","currency":"USD"},"lines":[{"id":"ol_1","type":"rollover","status":"sent","amount":{"value":"1250.00","currency":"USD"}}],"createdAt":"2026-10-01T16:20:05Z","updatedAt":"2026-10-12T14:03:11Z"}';

  private class OrdersMock implements HttpCalloutMock {
    final Integer status;
    final String body;
    final String retryAfter;
    final Boolean unreachable;
    String lastEndpoint;

    OrdersMock(Integer status, String body) {
      this(status, body, null, false);
    }

    OrdersMock(
      Integer status,
      String body,
      String retryAfter,
      Boolean unreachable
    ) {
      this.status = status;
      this.body = body;
      this.retryAfter = retryAfter;
      this.unreachable = unreachable;
    }

    public HttpResponse respond(HttpRequest request) {
      lastEndpoint = request.getEndpoint();
      if (unreachable) {
        throw new CalloutException('Unable to tunnel through proxy.');
      }
      HttpResponse response = new HttpResponse();
      response.setStatusCode(status);
      response.setBody(body);
      if (retryAfter != null) {
        response.setHeader('Retry-After', retryAfter);
      }
      return response;
    }
  }

  private static External_Order__c insertOrder() {
    Account account = new Account(
      Name = 'AC-260914-017-2231',
      Orders_Account_Id__c = 'acct_8f3c2a'
    );
    insert as system account;
    External_Order__c order = new External_Order__c(
      Name = 'OR-261001-017-2231',
      Order_Id__c = 'ord_77d1e9',
      Account__c = account.Id,
      Status__c = 'sent'
    );
    insert as system order;
    return order;
  }

  private static Account insertPlaceholderAccount() {
    Account account = new Account(
      Name = 'AC-260914-017-2231',
      Orders_Account_Id__c = 'acct_8f3c2a'
    );
    insert as system account;
    return account;
  }

  private static String accountName(Id accountId) {
    return [SELECT Name FROM Account WHERE Id = :accountId WITH SYSTEM_MODE]
    .Name;
  }

  // --- Client

  @IsTest
  static void clientReadsAnOrderThroughTheNamedCredential() {
    OrdersMock mock = new OrdersMock(200, ORDER_JSON);
    Test.setMock(HttpCalloutMock.class, mock);

    OrdersApiClient.OrderDetails order = OrdersApiClient.getOrder('ord_77d1e9');

    Assert.areEqual('callout:Orders_API/orders/ord_77d1e9', mock.lastEndpoint);
    Assert.areEqual('p_4411', order.participantRef);
    Assert.areEqual('1250.00', order.amount.value);
    Assert.areEqual('USD', order.amount.currencyCode);
    Assert.areEqual(1, order.lines.size());
    Assert.areEqual('rollover', order.lines[0].type);
  }

  @IsTest
  static void clientEncodesIdsInThePath() {
    OrdersMock mock = new OrdersMock(200, ACCOUNT_JSON);
    Test.setMock(HttpCalloutMock.class, mock);

    OrdersApiClient.getAccountName('a/b c');

    Assert.areEqual('callout:Orders_API/accounts/a%2Fb+c', mock.lastEndpoint);
  }

  @IsTest
  static void clientMapsFailuresToTypedErrors() {
    Test.setMock(HttpCalloutMock.class, new OrdersMock(404, '{}'));
    try {
      OrdersApiClient.getOrder('ord_x');
      Assert.fail('Expected NotFoundException');
    } catch (OrdersApiClient.NotFoundException expected) {
      Assert.isNotNull(expected.getMessage());
    }

    Test.setMock(
      HttpCalloutMock.class,
      new OrdersMock(429, '{}', '90', false)
    );
    try {
      OrdersApiClient.getOrder('ord_x');
      Assert.fail('Expected RateLimitedException');
    } catch (OrdersApiClient.RateLimitedException expected) {
      Assert.areEqual(90, expected.retryAfterSeconds);
    }

    Test.setMock(
      HttpCalloutMock.class,
      new OrdersMock(429, '{}', 'soon', false)
    );
    try {
      OrdersApiClient.getOrder('ord_x');
      Assert.fail('Expected RateLimitedException');
    } catch (OrdersApiClient.RateLimitedException expected) {
      Assert.areEqual(60, expected.retryAfterSeconds, 'default if unparseable');
    }

    for (OrdersMock failing : new List<OrdersMock>{
      new OrdersMock(503, 'down'),
      new OrdersMock(200, 'not json'),
      new OrdersMock(200, '[]'),
      new OrdersMock(200, '', null, true)
    }) {
      Test.setMock(HttpCalloutMock.class, failing);
      try {
        OrdersApiClient.getOrder('ord_x');
        Assert.fail('Expected UnavailableException');
      } catch (OrdersApiClient.UnavailableException expected) {
        Assert.isNotNull(expected.getMessage());
      }
    }
  }

  // --- Enrichment

  @IsTest
  static void enrichmentReplacesThePlaceholderName() {
    Account account = insertPlaceholderAccount();
    Test.setMock(HttpCalloutMock.class, new OrdersMock(200, ACCOUNT_JSON));

    Test.startTest();
    System.enqueueJob(new AccountEnrichmentJob(new Set<Id>{ account.Id }));
    Test.stopTest();

    Assert.areEqual('Northwind Plan Sponsor LLC', accountName(account.Id));
    Assert.isNull(AccountEnrichmentJob.scheduledDelayMinutes);
  }

  @IsTest
  static void enrichmentWaitsAsToldOnRateLimit() {
    Account account = insertPlaceholderAccount();
    Test.setMock(
      HttpCalloutMock.class,
      new OrdersMock(429, '{}', '90', false)
    );

    Test.startTest();
    System.enqueueJob(new AccountEnrichmentJob(new Set<Id>{ account.Id }));
    Test.stopTest();

    Assert.areEqual('AC-260914-017-2231', accountName(account.Id));
    Assert.areEqual(2, AccountEnrichmentJob.scheduledDelayMinutes);
  }

  @IsTest
  static void enrichmentKeepsThePlaceholderWhenOrdersIsDown() {
    Account account = insertPlaceholderAccount();
    Test.setMock(HttpCalloutMock.class, new OrdersMock(503, 'down'));

    Test.startTest();
    System.enqueueJob(new AccountEnrichmentJob(new Set<Id>{ account.Id }));
    Test.stopTest();

    Assert.areEqual('AC-260914-017-2231', accountName(account.Id));
    Assert.isNull(
      AccountEnrichmentJob.scheduledDelayMinutes,
      'only a rate limit is worth retrying'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Integration_Error__c
        WHERE Source__c = :IntegrationErrorLog.ENRICHMENT
        WITH SYSTEM_MODE
      ],
      'the job finishes as Completed, so the failure has to be recorded'
    );
  }

  @IsTest
  static void firstEventForANewAccountTriggersEnrichment() {
    OrdersTestData.configureSecret();
    Test.setMock(HttpCalloutMock.class, new OrdersMock(200, ACCOUNT_JSON));

    Test.startTest();
    Integer status = OrdersTestData.deliver(
      OrdersTestData.body('evt_1', 'order.sent', '2026-10-12T14:03:11Z')
    );
    Test.stopTest();

    Assert.areEqual(OrdersWebhookService.OK, status);
    Assert.areEqual(
      'Northwind Plan Sponsor LLC',
      OrdersTestData.orderById(OrdersTestData.ORDER_ID).Account__r.Name
    );
  }

  // --- Controller

  private static String liveReadError(Id orderId) {
    try {
      OrderDetailsController.getLiveDetails(orderId);
      Assert.fail('Expected an AuraHandledException');
    } catch (AuraHandledException expected) {
      return expected.getMessage();
    }
    return null;
  }

  @IsTest
  static void controllerReturnsLiveDetails() {
    External_Order__c order = insertOrder();
    Test.setMock(HttpCalloutMock.class, new OrdersMock(200, ORDER_JSON));

    Test.startTest();
    OrdersApiClient.OrderDetails details = OrderDetailsController.getLiveDetails(
      order.Id
    );
    Test.stopTest();

    Assert.areEqual('p_4411', details.participantRef);
  }

  @IsTest
  static void controllerGivesFriendlyErrors() {
    External_Order__c order = insertOrder();
    Test.startTest();

    Test.setMock(HttpCalloutMock.class, new OrdersMock(404, '{}'));
    Assert.isTrue(liveReadError(order.Id).contains('no record'));

    Test.setMock(
      HttpCalloutMock.class,
      new OrdersMock(429, '{}', '30', false)
    );
    Assert.isTrue(liveReadError(order.Id).contains('30 seconds'));

    Test.setMock(HttpCalloutMock.class, new OrdersMock(503, 'down'));
    Assert.isTrue(liveReadError(order.Id).contains('unavailable'));
    Test.stopTest();
  }

  @IsTest
  static void controllerRefusesAUserWhoCannotSeeTheOrder() {
    External_Order__c order = insertOrder();
    OrdersMock mock = new OrdersMock(200, ORDER_JSON);
    Test.setMock(HttpCalloutMock.class, mock);

    Profile noAdmin = [
      SELECT Id
      FROM Profile
      WHERE UserLicense.Name = 'Salesforce' AND PermissionsViewAllData = FALSE
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    User outsider = new User(
      Alias = 'outsider',
      Email = 'outsider@example.test',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Outsider',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = noAdmin.Id,
      TimeZoneSidKey = 'America/New_York',
      Username = 'outsider' + DateTime.now().getTime() + '@example.test'
    );

    System.runAs(outsider) {
      Assert.isTrue(liveReadError(order.Id).contains('access'));
    }
    Assert.isNull(mock.lastEndpoint, 'must not call out for that user');
  }
}
