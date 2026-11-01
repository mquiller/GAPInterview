/** Builds spec-shaped event bodies and signatures for tests. */
@IsTest
public class OrdersTestData {
  public static final String SECRET = 'orders-takehome-2026';
  public static final String ACCOUNT_ID = 'acct_8f3c2a';
  public static final String ACCOUNT_FRIENDLY_ID = 'AC-260914-017-2231';
  public static final String ORDER_ID = 'ord_77d1e9';
  public static final String ORDER_FRIENDLY_ID = 'OR-261001-017-2231';

  public static void configureSecret() {
    insert as system new Orders_Integration_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Webhook_Secret__c = SECRET
    );
  }

  public static String body(
    String eventId,
    String eventType,
    String occurredAt
  ) {
    return body(eventId, eventType, occurredAt, ORDER_ID, ORDER_FRIENDLY_ID);
  }

  public static String body(
    String eventId,
    String eventType,
    String occurredAt,
    String orderId,
    String orderFriendlyId
  ) {
    return body(
      eventId,
      eventType,
      occurredAt,
      orderId,
      orderFriendlyId,
      ACCOUNT_ID,
      ACCOUNT_FRIENDLY_ID
    );
  }

  public static String body(
    String eventId,
    String eventType,
    String occurredAt,
    String orderId,
    String orderFriendlyId,
    String accountId,
    String accountFriendlyId
  ) {
    return JSON.serialize(
      new Map<String, Object>{
        'subscriptionId' => 'sub_a1b2c3d4e5f67890abcdef12',
        'event' => new Map<String, Object>{
          'id' => eventId,
          'type' => eventType,
          'occurredAt' => occurredAt,
          'version' => '1.0'
        },
        'data' => new Map<String, Object>{
          'orderId' => orderId,
          'orderFriendlyId' => orderFriendlyId,
          'accountId' => accountId,
          'accountFriendlyId' => accountFriendlyId
        }
      }
    );
  }

  public static String sign(String body) {
    return EncodingUtil.convertToHex(
      Crypto.generateMac(
        'hmacSHA256',
        Blob.valueOf(body),
        Blob.valueOf(SECRET)
      )
    );
  }

  /** Signs and delivers a body as the sender would. */
  public static Integer deliver(String body) {
    stubOrdersApi();
    return OrdersWebhookService.handle(Blob.valueOf(body), sign(body));
  }

  /**
   * A first event for a new account enqueues enrichment, and enqueued jobs run when
   * the test ends, so any test delivering events needs a callout mock in place.
   */
  public static void stubOrdersApi() {
    Test.setMock(HttpCalloutMock.class, new AccountNameMock());
  }

  private class AccountNameMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      response.setBody('{"name":"Northwind Plan Sponsor LLC"}');
      return response;
    }
  }

  public static External_Order__c orderById(String orderId) {
    return [
      SELECT
        Id,
        Name,
        Status__c,
        Status_Changed_At__c,
        Last_Event_Id__c,
        Account__c,
        Account__r.Name,
        Account__r.Orders_Account_Id__c
      FROM External_Order__c
      WHERE Order_Id__c = :orderId
      WITH SYSTEM_MODE
    ];
  }

  public static Order_Event__c eventById(String eventId) {
    return [
      SELECT Id, Processing_Status__c, Error__c, Order__c
      FROM Order_Event__c
      WHERE Event_Id__c = :eventId
      WITH SYSTEM_MODE
    ];
  }
}
