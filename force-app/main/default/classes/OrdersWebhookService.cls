/**
 * The webhook's rules, independent of HTTP: verify, parse, claim, apply.
 * Returns the status code to send, so anonymous Apex and tests can call it directly.
 *
 * The sender suspends the subscription after three failed retries, so one bad event
 * must not take down the feed. Once an event is verified and stored it is our problem:
 * we return 200 and record any failure on the row. Non-2xx is only for a bad signature
 * or for when nothing could be saved, where a redelivery is actually useful.
 *
 * Without sharing, and every query and DML is explicitly system mode: runs as the Site
 * guest user, who has no object or record access by design. It does nothing with
 * records until the signature has been verified.
 */
public without sharing class OrdersWebhookService {
  public static final Integer OK = 200;
  public static final Integer UNAUTHORIZED = 401;
  public static final Integer SERVER_ERROR = 500;

  public static final String RECEIVED = 'Received';
  public static final String UNPROCESSABLE = 'Unprocessable';


  private static final Integer PAYLOAD_MAX_LENGTH = Order_Event__c.Raw_Payload__c.getDescribe().getLength();
  private static final Integer ERROR_MAX_LENGTH = Order_Event__c.Error__c.getDescribe().getLength();
  private static final Integer REPLAY_BATCH_SIZE = 200;

  public static Integer handle(Blob rawBody, String signature) {
    Orders_Integration_Settings__c settings = Orders_Integration_Settings__c.getOrgDefaults();
    if (String.isBlank(settings.Webhook_Secret__c)) {
      System.debug(
        LoggingLevel.ERROR,
        'Orders webhook secret is not configured.'
      );
      return SERVER_ERROR;
    }
    if (!OrdersSignature.isValid(rawBody, signature, settings.Webhook_Secret__c)) {
      return UNAUTHORIZED;
    }

    Savepoint beforeAnyWork = Database.setSavepoint();
    try {
      Order_Event__c row = buildRow(rawBody);
      if (String.isNotBlank(settings.Default_Owner_Id__c)) {
        row.OwnerId = settings.Default_Owner_Id__c;
      }
      // The unique index on Event_Id__c is the idempotency guard: of two deliveries
      // of one event, even concurrent ones, exactly one insert succeeds.
      Database.SaveResult claim = Database.insert(row, false, AccessLevel.SYSTEM_MODE);
      if (!claim.isSuccess()) {
        if (OrderEventProcessor.isDuplicate(claim.getErrors())) {
          return OK;
        }
        System.debug(
          LoggingLevel.ERROR,
          'Could not store event: ' + claim.getErrors()
        );
        return SERVER_ERROR;
      }
      if (row.Processing_Status__c == RECEIVED) {
        apply(new List<Order_Event__c>{ row });
      }
      return OK;
    } catch (Exception e) {
      Database.rollback(beforeAnyWork);
      System.debug(
        LoggingLevel.ERROR,
        'Unexpected webhook failure: ' + e.getMessage()
      );
      return SERVER_ERROR;
    }
  }

  /** Re-runs events that failed to apply. Rows already applied are never touched. */
  public static Integer replayFailed() {
    List<Order_Event__c> rows = [
      SELECT Id, Raw_Payload__c
      FROM Order_Event__c
      WHERE Processing_Status__c = :OrderEventProcessor.FAILED
      WITH SYSTEM_MODE
      ORDER BY CreatedDate
      LIMIT :REPLAY_BATCH_SIZE
    ];
    if (!rows.isEmpty()) {
      apply(rows);
    }
    return rows.size();
  }

  /**
   * Applies inside a savepoint so a thrown failure (a lock timeout, say) leaves
   * no partial order changes, then records the failure on the rows.
   */
  private static void apply(List<Order_Event__c> rows) {
    Savepoint beforeApply = Database.setSavepoint();
    try {
      enqueueEnrichment(OrderEventProcessor.process(rows).newAccountIds);
    } catch (Exception e) {
      Database.rollback(beforeApply);
      List<Order_Event__c> failedRows = new List<Order_Event__c>();
      for (Order_Event__c row : rows) {
        failedRows.add(
          new Order_Event__c(
            Id = row.Id,
            Processing_Status__c = OrderEventProcessor.FAILED,
            Error__c = e.getMessage().abbreviate(ERROR_MAX_LENGTH)
          )
        );
      }
      update as system failedRows;
    }
  }

  /** Best effort: a placeholder account name must never cost us an order status. */
  private static void enqueueEnrichment(Set<Id> newAccountIds) {
    if (newAccountIds.isEmpty()) {
      return;
    }
    try {
      System.enqueueJob(new AccountEnrichmentJob(newAccountIds));
    } catch (AsyncException e) {
      System.debug(
        LoggingLevel.WARN,
        'Could not enqueue account enrichment: ' + e.getMessage()
      );
    }
  }

  /** A row for the inbox. Well-formed events start as Received; anything else is parked. */
  private static Order_Event__c buildRow(Blob rawBody) {
    String body = bodyAsText(rawBody);
    try {
      OrderEventPayload payload = OrderEventPayload.parse(body);
      Order_Event__c row = new Order_Event__c(
        Event_Id__c = payload.eventId,
        Event_Type__c = payload.eventType,
        Occurred_At__c = payload.occurredAt,
        Orders_Order_Id__c = payload.orderId,
        Processing_Status__c = RECEIVED,
        Raw_Payload__c = body.abbreviate(PAYLOAD_MAX_LENGTH)
      );
      if (OrderStatuses.fromEventType(payload.eventType) == null) {
        row.Processing_Status__c = UNPROCESSABLE;
        row.Error__c = 'Unknown event type: ' + payload.eventType;
      }
      return row;
    } catch (OrderEventPayload.InvalidPayloadException e) {
      // No trustworthy event.id, so key on the body: a redelivery is still a duplicate.
      return new Order_Event__c(
        Event_Id__c = 'invalid:' +
          EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', rawBody)),
        Processing_Status__c = UNPROCESSABLE,
        Error__c = e.getMessage().abbreviate(ERROR_MAX_LENGTH),
        Raw_Payload__c = body.abbreviate(PAYLOAD_MAX_LENGTH)
      );
    }
  }

  /** Blob.toString() throws on bytes that aren't valid UTF-8; keep them as base64 instead. */
  private static String bodyAsText(Blob rawBody) {
    try {
      return rawBody.toString();
    } catch (Exception notUtf8) {
      return 'base64:' + EncodingUtil.base64Encode(rawBody);
    }
  }
}
