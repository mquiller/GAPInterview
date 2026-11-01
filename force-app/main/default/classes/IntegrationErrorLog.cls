/**
 * Keeps failures that have no Order_Event__c row to live on, because System.debug
 * only records anything while someone has a trace flag active.
 *
 * Two rules for callers: write after any rollback, or the rollback removes the log
 * row too, and write after any callouts, because Apex can't call out after DML.
 *
 * Best effort: failing to log must never change the outcome of the work being logged.
 * A governor limit exception can't be caught, so that transaction logs nothing.
 *
 * Without sharing, explicit system mode: often runs as the Site guest user, who has no
 * record access.
 */
public without sharing class IntegrationErrorLog {
  public static final String WEBHOOK = 'Webhook';
  public static final String CONTENTION = 'Webhook contention';
  public static final String ENRICHMENT = 'Account enrichment';

  private static final Integer MESSAGE_MAX_LENGTH = Integration_Error__c.Message__c.getDescribe().getLength();
  private static final Integer EVENT_ID_MAX_LENGTH = Integration_Error__c.Event_Id__c.getDescribe().getLength();

  public static void record(String source, String message, String eventId) {
    save(new List<Integration_Error__c>{ build(source, message, eventId) });
  }

  /** For code that can't do DML yet: build rows during callouts, save them afterwards. */
  public static Integration_Error__c build(
    String source,
    String message,
    String eventId
  ) {
    System.debug(LoggingLevel.ERROR, source + ': ' + message);
    return new Integration_Error__c(
      Source__c = source,
      Message__c = String.valueOf(message).abbreviate(MESSAGE_MAX_LENGTH),
      Event_Id__c = eventId?.abbreviate(EVENT_ID_MAX_LENGTH)
    );
  }

  public static void save(List<Integration_Error__c> errors) {
    if (errors.isEmpty()) {
      return;
    }
    try {
      String ownerId = Orders_Integration_Settings__c.getOrgDefaults()
        .Default_Owner_Id__c;
      if (String.isNotBlank(ownerId)) {
        for (Integration_Error__c error : errors) {
          error.OwnerId = ownerId;
        }
      }
      for (Database.SaveResult result : Database.insert(
        errors,
        false,
        AccessLevel.SYSTEM_MODE
      )) {
        if (!result.isSuccess()) {
          System.debug(
            LoggingLevel.ERROR,
            'Could not save integration error: ' + result.getErrors()
          );
        }
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Could not save integration error: ' + e.getMessage()
      );
    }
  }
}
