@IsTest
private class OrdersWebhookServiceTest {
  @TestSetup
  static void setup() {
    OrdersTestData.configureSecret();
  }

  /** The spec's sample sequence and its stated end state. */
  @IsTest
  static void specSampleSequenceReachesExpectedEndState() {
    String second = 'ord_52ab10';
    List<String> bodies = new List<String>{
      OrdersTestData.body(
        'evt_001',
        'order.inProgress',
        '2026-10-10T10:00:00Z'
      ),
      OrdersTestData.body(
        'evt_002',
        'order.waitingForParticipant',
        '2026-10-11T10:00:00Z'
      ),
      OrdersTestData.body(
        'evt_001',
        'order.inProgress',
        '2026-10-10T10:00:00Z'
      ),
      OrdersTestData.body('evt_004', 'order.sent', '2026-10-12T14:03:11Z'),
      OrdersTestData.body(
        'evt_003',
        'order.cleared',
        '2026-10-09T09:41:27Z',
        second,
        'OR-260922-017-1187'
      )
    };

    for (String body : bodies) {
      Assert.areEqual(OrdersWebhookService.OK, OrdersTestData.deliver(body));
    }

    Assert.areEqual(
      'sent',
      OrdersTestData.orderById(OrdersTestData.ORDER_ID).Status__c
    );
    Assert.areEqual('cleared', OrdersTestData.orderById(second).Status__c);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Order_Event__c WHERE Event_Id__c = 'evt_001' WITH SYSTEM_MODE],
      'evt_001 must be processed once'
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Account WITH SYSTEM_MODE]);
  }

  @IsTest
  static void newAccountUsesFriendlyIdAsPlaceholderName() {
    OrdersTestData.deliver(
      OrdersTestData.body('evt_1', 'order.sent', '2026-10-12T14:03:11Z')
    );

    External_Order__c order = OrdersTestData.orderById(OrdersTestData.ORDER_ID);
    Assert.areEqual(OrdersTestData.ACCOUNT_FRIENDLY_ID, order.Account__r.Name);
    Assert.areEqual(
      OrdersTestData.ACCOUNT_ID,
      order.Account__r.Orders_Account_Id__c
    );
    Assert.areEqual(OrdersTestData.ORDER_FRIENDLY_ID, order.Name);
  }

  @IsTest
  static void existingAccountIsReusedAndKeepsItsName() {
    insert as system new Account(
      Name = 'Northwind Plan Sponsor LLC',
      Orders_Account_Id__c = OrdersTestData.ACCOUNT_ID
    );

    OrdersTestData.deliver(
      OrdersTestData.body('evt_1', 'order.sent', '2026-10-12T14:03:11Z')
    );

    Assert.areEqual(
      'Northwind Plan Sponsor LLC',
      OrdersTestData.orderById(OrdersTestData.ORDER_ID).Account__r.Name
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Account WITH SYSTEM_MODE]);
  }

  @IsTest
  static void badSignatureIsRejectedAndStoresNothing() {
    String body = OrdersTestData.body(
      'evt_1',
      'order.sent',
      '2026-10-12T14:03:11Z'
    );

    Assert.areEqual(
      OrdersWebhookService.UNAUTHORIZED,
      OrdersWebhookService.handle(Blob.valueOf(body), 'deadbeef')
    );
    Assert.areEqual(
      OrdersWebhookService.UNAUTHORIZED,
      OrdersWebhookService.handle(Blob.valueOf(body), null)
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Order_Event__c WITH SYSTEM_MODE]);
    Assert.areEqual(0, [SELECT COUNT() FROM External_Order__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void tamperedBodyIsRejected() {
    String body = OrdersTestData.body(
      'evt_1',
      'order.sent',
      '2026-10-12T14:03:11Z'
    );
    String signature = OrdersTestData.sign(body);
    String tampered = body.replace('order.sent', 'order.cleared');

    Assert.areEqual(
      OrdersWebhookService.UNAUTHORIZED,
      OrdersWebhookService.handle(Blob.valueOf(tampered), signature)
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Order_Event__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void missingSecretFailsClosed() {
    delete as system [SELECT Id FROM Orders_Integration_Settings__c WITH SYSTEM_MODE];
    String body = OrdersTestData.body(
      'evt_1',
      'order.sent',
      '2026-10-12T14:03:11Z'
    );

    Assert.areEqual(
      OrdersWebhookService.SERVER_ERROR,
      OrdersTestData.deliver(body)
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Order_Event__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void signedButMalformedIsParkedNotRejected() {
    String body = '{"not":"an event"}';

    Assert.areEqual(OrdersWebhookService.OK, OrdersTestData.deliver(body));
    Assert.areEqual(OrdersWebhookService.OK, OrdersTestData.deliver(body));

    List<Order_Event__c> rows = [
      SELECT Processing_Status__c, Raw_Payload__c, Event_Id__c
      FROM Order_Event__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(1, rows.size(), 'redelivery must dedupe on the body hash');
    Assert.areEqual(
      OrdersWebhookService.UNPROCESSABLE,
      rows[0].Processing_Status__c
    );
    Assert.areEqual(body, rows[0].Raw_Payload__c);
  }

  @IsTest
  static void unknownEventTypeIsParkedWithoutTouchingOrders() {
    String body = OrdersTestData.body(
      'evt_new',
      'order.archived',
      '2026-10-12T14:03:11Z'
    );

    Assert.areEqual(OrdersWebhookService.OK, OrdersTestData.deliver(body));

    Assert.areEqual(
      OrdersWebhookService.UNPROCESSABLE,
      OrdersTestData.eventById('evt_new').Processing_Status__c
    );
    Assert.areEqual(0, [SELECT COUNT() FROM External_Order__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void concurrentInsertCountsAsContentionButOtherFailuresDoNot() {
    Account account = new Account(Name = 'Northwind');
    insert as system account;
    External_Order__c first = new External_Order__c(
      Name = 'A',
      Order_Id__c = 'ord_same',
      Account__c = account.Id
    );
    insert as system first;

    // The same DmlException a losing concurrent insert gets.
    try {
      insert as system new External_Order__c(
        Name = 'B',
        Order_Id__c = 'ord_same',
        Account__c = account.Id
      );
      Assert.fail('Expected DUPLICATE_VALUE');
    } catch (DmlException e) {
      Assert.isTrue(OrdersWebhookService.isContention(e));
    }

    // A permanent failure must not be retried by the sender forever.
    try {
      insert as system new External_Order__c(
        Name = 'X'.repeat(81),
        Order_Id__c = 'ord_other',
        Account__c = account.Id
      );
      Assert.fail('Expected STRING_TOO_LONG');
    } catch (DmlException e) {
      Assert.isFalse(OrdersWebhookService.isContention(e));
    }
  }

  @IsTest
  static void applyFailureReturns200AndCanBeReplayed() {
    // Name is 80 characters, so this order can't be saved: a real DML failure.
    String body = OrdersTestData.body(
      'evt_bad',
      'order.sent',
      '2026-10-12T14:03:11Z',
      OrdersTestData.ORDER_ID,
      'X'.repeat(81)
    );

    Assert.areEqual(OrdersWebhookService.OK, OrdersTestData.deliver(body));

    Order_Event__c failed = OrdersTestData.eventById('evt_bad');
    Assert.areEqual(OrderEventProcessor.FAILED, failed.Processing_Status__c);
    Assert.isNotNull(failed.Error__c);
    Assert.isNull(failed.Order__c);
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Account WITH SYSTEM_MODE],
      'the failed attempt leaves no partial work behind'
    );

    // Whatever was wrong gets fixed; replay then uses the same code path as live delivery.
    failed.Raw_Payload__c = OrdersTestData.body(
      'evt_bad',
      'order.sent',
      '2026-10-12T14:03:11Z'
    );
    update as system failed;

    Assert.areEqual(1, OrdersWebhookService.replayFailed());

    Order_Event__c replayed = OrdersTestData.eventById('evt_bad');
    Assert.areEqual(OrderEventProcessor.APPLIED, replayed.Processing_Status__c);
    Assert.isNull(replayed.Error__c);
    Assert.areEqual(
      'sent',
      OrdersTestData.orderById(OrdersTestData.ORDER_ID).Status__c
    );
  }
}
