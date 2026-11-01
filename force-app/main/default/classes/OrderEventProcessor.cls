/**
 * Applies stored events to Accounts and External Orders. Works on inbox rows, not
 * HTTP requests, so live delivery (one row) and replay (many rows) share one code path.
 *
 * Bulk-safe: query and DML counts stay constant however many rows are passed.
 * All or nothing: any failure throws, and OrdersWebhookService decides what it means.
 *
 * Without sharing, and every query and DML is explicitly system mode: the webhook runs
 * as the Site guest user, who has no access to business data by design. The signature
 * check has already authenticated the sender by the time this runs.
 */
public without sharing class OrderEventProcessor {
  public static final String APPLIED = 'Applied';
  public static final String STALE = 'Stale';
  public static final String FAILED = 'Failed';

  /**
   * Updates each row's status and order link, and saves the rows.
   * @return Accounts created here, which still carry a placeholder name.
   */
  public static Set<Id> process(List<Order_Event__c> rows) {
    Map<Id, OrderEventPayload> payloads = new Map<Id, OrderEventPayload>();
    for (Order_Event__c row : rows) {
      payloads.put(row.Id, OrderEventPayload.parse(row.Raw_Payload__c));
    }

    Map<String, Id> accountIds = existingAccountIds(payloads.values());
    List<Account> newAccounts = buildMissingAccounts(
      payloads.values(),
      accountIds
    );
    insert as system newAccounts;
    for (Account account : newAccounts) {
      accountIds.put(account.Orders_Account_Id__c, account.Id);
    }

    applyStatuses(rows, payloads, accountIds);
    update as system rows;
    return new Map<Id, Account>(newAccounts).keySet();
  }

  /** @return Salesforce Account Id by Orders account ID. */
  private static Map<String, Id> existingAccountIds(
    List<OrderEventPayload> payloads
  ) {
    Set<String> ordersAccountIds = new Set<String>();
    for (OrderEventPayload payload : payloads) {
      ordersAccountIds.add(payload.accountId);
    }

    Map<String, Id> accountIds = new Map<String, Id>();
    for (Account account : [
      SELECT Id, Orders_Account_Id__c
      FROM Account
      WHERE Orders_Account_Id__c IN :ordersAccountIds
      WITH SYSTEM_MODE
    ]) {
      accountIds.put(account.Orders_Account_Id__c, account.Id);
    }
    return accountIds;
  }

  private static List<Account> buildMissingAccounts(
    List<OrderEventPayload> payloads,
    Map<String, Id> accountIds
  ) {
    Id ownerId = defaultOwnerId();
    Map<String, Account> missing = new Map<String, Account>();
    for (OrderEventPayload payload : payloads) {
      if (!accountIds.containsKey(payload.accountId)) {
        // The event has no account name. The friendly ID stands in until enrichment.
        Account account = new Account(
          Name = payload.accountFriendlyId,
          Orders_Account_Id__c = payload.accountId,
          Orders_Friendly_Id__c = payload.accountFriendlyId
        );
        if (ownerId != null) {
          account.OwnerId = ownerId;
        }
        missing.put(payload.accountId, account);
      }
    }
    return missing.values();
  }

  /**
   * The rank rule. Locks existing orders so two concurrent events for one order
   * can't both read the old status and overwrite each other.
   */
  private static void applyStatuses(
    List<Order_Event__c> rows,
    Map<Id, OrderEventPayload> payloads,
    Map<String, Id> accountIds
  ) {
    Set<String> ordersOrderIds = new Set<String>();
    for (OrderEventPayload payload : payloads.values()) {
      ordersOrderIds.add(payload.orderId);
    }

    Map<String, External_Order__c> orders = new Map<String, External_Order__c>();
    for (External_Order__c order : [
      SELECT Id, Order_Id__c, Status__c
      FROM External_Order__c
      WHERE Order_Id__c IN :ordersOrderIds
      WITH SYSTEM_MODE
      FOR UPDATE
    ]) {
      orders.put(order.Order_Id__c, order);
    }

    Map<String, External_Order__c> toSave = new Map<String, External_Order__c>();
    for (Order_Event__c row : rows) {
      OrderEventPayload payload = payloads.get(row.Id);
      External_Order__c order = orders.get(payload.orderId);
      if (order == null) {
        order = new External_Order__c(
          Name = payload.orderFriendlyId,
          Order_Id__c = payload.orderId,
          Account__c = accountIds.get(payload.accountId)
        );
        orders.put(payload.orderId, order);
      }

      String status = OrderStatuses.fromEventType(payload.eventType);
      if (OrderStatuses.rank(status) > OrderStatuses.rank(order.Status__c)) {
        order.Status__c = status;
        order.Status_Changed_At__c = payload.occurredAt;
        order.Last_Event_Id__c = payload.eventId;
        toSave.put(payload.orderId, order);
        row.Processing_Status__c = APPLIED;
      } else {
        row.Processing_Status__c = STALE;
      }
      row.Error__c = null;
    }
    upsert as system toSave.values();

    for (Order_Event__c row : rows) {
      row.Order__c = orders.get(payloads.get(row.Id).orderId).Id;
    }
  }

  private static Id defaultOwnerId() {
    String ownerId = Orders_Integration_Settings__c.getOrgDefaults()
      .Default_Owner_Id__c;
    return String.isBlank(ownerId) ? null : Id.valueOf(ownerId);
  }
}
