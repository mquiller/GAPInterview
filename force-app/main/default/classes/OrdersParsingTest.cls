/** Pure-logic tests: signature, payload parsing and status ranks. No records involved. */
@IsTest
private class OrdersParsingTest {
  @IsTest
  static void signatureMatchesAKnownVector() {
    // Computed outside Salesforce, so this would catch a wrong algorithm or encoding:
    //   printf '%s' '{"a":1}' | openssl dgst -sha256 -hmac orders-takehome-2026
    String body = '{"a":1}';
    String expected = '201e077711270694e04f7e2b28f4b584982e099e66fa2f511ab6a16a9dfbce0f';
    Assert.isTrue(
      OrdersSignature.isValid(
        Blob.valueOf(body),
        expected,
        'orders-takehome-2026'
      )
    );
    Assert.isTrue(
      OrdersSignature.isValid(
        Blob.valueOf(body),
        expected.toUpperCase(),
        'orders-takehome-2026'
      ),
      'hex case must not matter'
    );
  }

  @IsTest
  static void signatureRejectsBadInput() {
    Blob body = Blob.valueOf('{"a":1}');
    Assert.isFalse(OrdersSignature.isValid(body, 'not-hex!', 'secret'));
    Assert.isFalse(OrdersSignature.isValid(body, 'abc', 'secret'));
    Assert.isFalse(OrdersSignature.isValid(body, '', 'secret'));
    Assert.isFalse(OrdersSignature.isValid(body, 'deadbeef', ''));
    Assert.isFalse(OrdersSignature.isValid(null, 'deadbeef', 'secret'));
  }

  @IsTest
  static void payloadParsesTheSpecShape() {
    OrderEventPayload payload = OrderEventPayload.parse(
      OrdersTestData.body('evt_1', 'order.sent', '2026-10-12T14:03:11Z')
    );

    Assert.areEqual('evt_1', payload.eventId);
    Assert.areEqual('order.sent', payload.eventType);
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 10, 12, 14, 3, 11),
      payload.occurredAt
    );
    Assert.areEqual(OrdersTestData.ORDER_ID, payload.orderId);
    Assert.areEqual(OrdersTestData.ORDER_FRIENDLY_ID, payload.orderFriendlyId);
    Assert.areEqual(OrdersTestData.ACCOUNT_ID, payload.accountId);
    Assert.areEqual(
      OrdersTestData.ACCOUNT_FRIENDLY_ID,
      payload.accountFriendlyId
    );
  }

  @IsTest
  static void payloadRejectsInvalidBodies() {
    List<String> invalid = new List<String>{
      'not json',
      '[]',
      '{}',
      '{"event":{},"data":{}}',
      '{"event":"text","data":{}}',
      // Valid shape with a required field missing, then an unparseable date.
      OrdersTestData.body('', 'order.sent', '2026-10-12T14:03:11Z'),
      OrdersTestData.body('evt_1', 'order.sent', 'yesterday')
    };
    for (String body : invalid) {
      try {
        OrderEventPayload.parse(body);
        Assert.fail('Expected rejection of: ' + body);
      } catch (OrderEventPayload.InvalidPayloadException expected) {
        Assert.isNotNull(expected.getMessage());
      }
    }
  }

  @IsTest
  static void statusRanksFollowTheSpecLifecycle() {
    List<String> lifecycle = new List<String>{
      'created',
      'inProgress',
      'waitingForParticipant',
      'sent',
      'cleared',
      'returned'
    };
    for (Integer i = 1; i < lifecycle.size(); i++) {
      Assert.isTrue(
        OrderStatuses.rank(lifecycle[i]) >
        OrderStatuses.rank(lifecycle[i - 1]),
        lifecycle[i] + ' must outrank ' + lifecycle[i - 1]
      );
    }
    Assert.areEqual(-1, OrderStatuses.rank(null));
    Assert.areEqual(-1, OrderStatuses.rank('archived'));
  }

  @IsTest
  static void eventTypesMapToStatuses() {
    Assert.areEqual('sent', OrderStatuses.fromEventType('order.sent'));
    Assert.areEqual(
      'waitingForParticipant',
      OrderStatuses.fromEventType('order.waitingForParticipant')
    );
    Assert.isNull(OrderStatuses.fromEventType('order.archived'));
    Assert.isNull(OrderStatuses.fromEventType('account.sent'));
    Assert.isNull(OrderStatuses.fromEventType(null));
  }
}
