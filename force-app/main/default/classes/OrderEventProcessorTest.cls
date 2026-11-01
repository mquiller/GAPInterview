@IsTest
private class OrderEventProcessorTest {
  private static Order_Event__c row(String eventId, String eventType) {
    return new Order_Event__c(
      Event_Id__c = eventId,
      Event_Type__c = eventType,
      Processing_Status__c = OrdersWebhookService.RECEIVED,
      Raw_Payload__c = OrdersTestData.body(
        eventId,
        eventType,
        '2026-10-12T14:03:11Z'
      )
    );
  }

  private static void processOne(String eventId, String eventType) {
    Order_Event__c event = row(eventId, eventType);
    insert as system event;
    OrderEventProcessor.process(new List<Order_Event__c>{ event });
  }

  private static String currentStatus() {
    return OrdersTestData.orderById(OrdersTestData.ORDER_ID).Status__c;
  }

  @IsTest
  static void lowerRankEventIsStaleAndLeavesStatusAlone() {
    processOne('e1', 'order.sent');
    processOne('e2', 'order.inProgress');

    Assert.areEqual('sent', currentStatus());
    Order_Event__c stale = OrdersTestData.eventById('e2');
    Assert.areEqual(OrderEventProcessor.STALE, stale.Processing_Status__c);
    Assert.isNotNull(stale.Order__c, 'stale events still join the timeline');
  }

  @IsTest
  static void timestampDoesNotOverrideRank() {
    // A higher-rank event wins even if its clock says it happened earlier.
    Order_Event__c later = row('e1', 'order.inProgress');
    later.Raw_Payload__c = OrdersTestData.body(
      'e1',
      'order.inProgress',
      '2026-10-20T00:00:00Z'
    );
    insert as system later;
    OrderEventProcessor.process(new List<Order_Event__c>{ later });

    Order_Event__c earlier = row('e2', 'order.sent');
    earlier.Raw_Payload__c = OrdersTestData.body(
      'e2',
      'order.sent',
      '2026-10-01T00:00:00Z'
    );
    insert as system earlier;
    OrderEventProcessor.process(new List<Order_Event__c>{ earlier });

    Assert.areEqual('sent', currentStatus());
  }

  @IsTest
  static void returnedCanFollowSentOrCleared() {
    processOne('e1', 'order.sent');
    processOne('e2', 'order.returned');
    Assert.areEqual('returned', currentStatus());
  }

  @IsTest
  static void lateClearedDoesNotOverwriteReturned() {
    processOne('e1', 'order.returned');
    processOne('e2', 'order.cleared');

    Assert.areEqual('returned', currentStatus());
    Assert.areEqual(
      OrderEventProcessor.STALE,
      OrdersTestData.eventById('e2').Processing_Status__c
    );
  }

  @IsTest
  static void batchWithSeveralEventsForOneOrderEndsOnHighestRank() {
    List<Order_Event__c> rows = new List<Order_Event__c>{
      row('e1', 'order.cleared'),
      row('e2', 'order.inProgress'),
      row('e3', 'order.sent')
    };
    insert as system rows;

    OrderEventProcessor.process(rows);

    External_Order__c order = OrdersTestData.orderById(OrdersTestData.ORDER_ID);
    Assert.areEqual('cleared', order.Status__c);
    Assert.areEqual('e1', order.Last_Event_Id__c);
  }

  @IsTest
  static void bulkBatchStaysWithinConstantQueryAndDmlCounts() {
    // 200 events across 100 orders and 10 new accounts, each order in both batch positions.
    List<Order_Event__c> rows = new List<Order_Event__c>();
    for (Integer i = 0; i < 100; i++) {
      String accountNumber = String.valueOf(Math.mod(i, 10));
      for (String eventType : new List<String>{ 'order.sent', 'order.inProgress' }) {
        String eventId = eventType + '-' + i;
        rows.add(
          new Order_Event__c(
            Event_Id__c = eventId,
            Event_Type__c = eventType,
            Processing_Status__c = OrdersWebhookService.RECEIVED,
            Raw_Payload__c = OrdersTestData.body(
              eventId,
              eventType,
              '2026-10-12T14:03:11Z',
              'ord_' + i,
              'OR-' + i,
              'acct_' + accountNumber,
              'AC-' + accountNumber
            )
          )
        );
      }
    }
    insert as system rows;

    Test.startTest();
    OrderEventProcessor.Result result = OrderEventProcessor.process(rows);
    Assert.isTrue(
      Limits.getQueries() <= 2,
      'Queries used: ' + Limits.getQueries()
    );
    Assert.isTrue(
      Limits.getDmlStatements() <= 4,
      'DML used: ' + Limits.getDmlStatements()
    );
    Test.stopTest();

    Assert.areEqual(10, result.newAccountIds.size());
    Assert.areEqual(10, [SELECT COUNT() FROM Account WITH SYSTEM_MODE]);
    Assert.areEqual(
      100,
      [SELECT COUNT() FROM External_Order__c WHERE Status__c = 'sent' WITH SYSTEM_MODE]
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Order_Event__c
        WHERE Processing_Status__c = :OrderEventProcessor.FAILED
        WITH SYSTEM_MODE
      ]
    );
  }
}
