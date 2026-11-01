@IsTest
private class OrdersWebhookResourceTest {
  private static Integer post(String body, Map<String, String> headers) {
    RestRequest request = new RestRequest();
    request.requestUri = '/services/apexrest/orders/events';
    request.httpMethod = 'POST';
    request.requestBody = Blob.valueOf(body);
    request.headers.putAll(headers);
    RestContext.request = request;
    RestContext.response = new RestResponse();
    OrdersTestData.stubOrdersApi();

    OrdersWebhookResource.receive();
    return RestContext.response.statusCode;
  }

  @IsTest
  static void validRequestIsAcceptedWithAnyHeaderCasing() {
    OrdersTestData.configureSecret();
    String body = OrdersTestData.body(
      'evt_1',
      'order.sent',
      '2026-10-12T14:03:11Z'
    );

    Integer status = post(
      body,
      new Map<String, String>{
        'orders-signature' => OrdersTestData.sign(body)
      }
    );

    Assert.areEqual(200, status);
    Assert.areEqual(
      '{"accepted":true}',
      RestContext.response.responseBody.toString()
    );
    Assert.areEqual(
      'sent',
      OrdersTestData.orderById(OrdersTestData.ORDER_ID).Status__c
    );
  }

  @IsTest
  static void missingSignatureHeaderGets401() {
    OrdersTestData.configureSecret();

    Integer status = post(
      OrdersTestData.body('evt_1', 'order.sent', '2026-10-12T14:03:11Z'),
      new Map<String, String>()
    );

    Assert.areEqual(401, status);
    Assert.areEqual(
      '{"accepted":false}',
      RestContext.response.responseBody.toString()
    );
  }
}
