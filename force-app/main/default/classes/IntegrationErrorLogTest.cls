@IsTest
private class IntegrationErrorLogTest {
  private static List<Integration_Error__c> savedErrors() {
    return [
      SELECT Source__c, Message__c, Event_Id__c, OwnerId
      FROM Integration_Error__c
      WITH SYSTEM_MODE
    ];
  }

  @IsTest
  static void recordSavesTheError() {
    IntegrationErrorLog.record(IntegrationErrorLog.WEBHOOK, 'boom', 'evt_1');

    List<Integration_Error__c> errors = savedErrors();
    Assert.areEqual(1, errors.size());
    Assert.areEqual(IntegrationErrorLog.WEBHOOK, errors[0].Source__c);
    Assert.areEqual('boom', errors[0].Message__c);
    Assert.areEqual('evt_1', errors[0].Event_Id__c);
  }

  @IsTest
  static void oversizedValuesAreTruncatedRatherThanLost() {
    IntegrationErrorLog.record(
      IntegrationErrorLog.WEBHOOK,
      'x'.repeat(40000),
      'y'.repeat(300)
    );

    List<Integration_Error__c> errors = savedErrors();
    Assert.areEqual(1, errors.size());
    Assert.areEqual(32768, errors[0].Message__c.length());
    Assert.areEqual(255, errors[0].Event_Id__c.length());
  }

  @IsTest
  static void rowsAreOwnedByTheDefaultOwner() {
    insert as system new Orders_Integration_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Default_Owner_Id__c = UserInfo.getUserId()
    );

    IntegrationErrorLog.record(IntegrationErrorLog.WEBHOOK, 'boom', null);

    Assert.areEqual(UserInfo.getUserId(), savedErrors()[0].OwnerId);
  }

  @IsTest
  static void aFailureToLogDoesNotThrow() {
    // Not a valid Id, so assigning or saving the owner fails.
    insert as system new Orders_Integration_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Default_Owner_Id__c = 'not-an-id'
    );

    IntegrationErrorLog.record(IntegrationErrorLog.WEBHOOK, 'boom', null);

    Assert.areEqual(0, savedErrors().size());
  }

  @IsTest
  static void anEventThatCannotBeStoredLeavesAnErrorRow() {
    OrdersTestData.configureSecret();
    // Event_Type__c holds 80 characters, so the claim insert fails on a real DML error.
    String body = OrdersTestData.body(
      'evt_unstorable',
      'order.' + 'x'.repeat(80),
      '2026-10-12T14:03:11Z'
    );

    Assert.areEqual(
      OrdersWebhookService.SERVER_ERROR,
      OrdersTestData.deliver(body)
    );

    Assert.areEqual(0, [SELECT COUNT() FROM Order_Event__c WITH SYSTEM_MODE]);
    List<Integration_Error__c> errors = savedErrors();
    Assert.areEqual(1, errors.size());
    Assert.areEqual(IntegrationErrorLog.WEBHOOK, errors[0].Source__c);
    Assert.areEqual('evt_unstorable', errors[0].Event_Id__c);
  }

  @IsTest
  static void aBadSignatureLogsNothing() {
    OrdersTestData.configureSecret();

    OrdersWebhookService.handle(Blob.valueOf('{}'), 'deadbeef');

    Assert.areEqual(
      0,
      savedErrors().size(),
      'unauthenticated requests must not be able to write rows'
    );
  }
}
