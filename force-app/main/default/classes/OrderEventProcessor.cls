/**
 * Applies stored events to Accounts and External Orders. Works on inbox rows, not
 * HTTP requests, so live delivery and replay of failed events share one code path.
 *
 * Bulk-safe: query and DML counts stay constant however many rows are passed.
 * Failures are per row: one bad event never blocks the others in the list.
 *
 * Without sharing, and every query and DML is explicitly system mode: the webhook runs
 * as the Site guest user, who has no object or record access by design. The signature
 * check has already authenticated the sender by the time this runs.
 */
public without sharing class OrderEventProcessor {
  public static final String APPLIED = 'Applied';
  public static final String STALE = 'Stale';
  public static final String FAILED = 'Failed';

  private static final Integer ERROR_MAX_LENGTH = Order_Event__c.Error__c.getDescribe().getLength();

  public class Result {
    /** Accounts created here that still carry a placeholder name. */
    public Set<Id> newAccountIds = new Set<Id>();
  }

  /**
   * Updates each row's status, error and order link in place, then saves the rows.
   * Throws only if the rows themselves can't be saved; the caller decides what that means.
   */
  public static Result process(List<Order_Event__c> rows) {
    Result result = new Result();
    List<EventItem> items = parseRows(rows);
    Map<String, Id> accountIds = resolveAccounts(items, result);

    List<EventItem> conflicted = applyToOrders(items, accountIds);
    if (!conflicted.isEmpty()) {
      // A concurrent transaction created the same order first and has now committed,
      // so a second pass finds its record and applies the rank rule against it.
      for (EventItem item : applyToOrders(conflicted, accountIds)) {
        item.fail('Could not create the order: concurrent insert conflict.');
      }
    }

    update as system rows;
    return result;
  }

  private static List<EventItem> parseRows(List<Order_Event__c> rows) {
    List<EventItem> items = new List<EventItem>();
    for (Order_Event__c row : rows) {
      try {
        items.add(
          new EventItem(row, OrderEventPayload.parse(row.Raw_Payload__c))
        );
      } catch (OrderEventPayload.InvalidPayloadException e) {
        row.Processing_Status__c = FAILED;
        row.Error__c = e.getMessage().abbreviate(ERROR_MAX_LENGTH);
      }
    }
    return items;
  }

  /** @return Salesforce Account Id by Orders account ID, creating any that don't exist yet. */
  private static Map<String, Id> resolveAccounts(
    List<EventItem> items,
    Result result
  ) {
    Map<String, String> friendlyIdByAccountId = new Map<String, String>();
    for (EventItem item : items) {
      friendlyIdByAccountId.put(
        item.payload.accountId,
        item.payload.accountFriendlyId
      );
    }

    Map<String, Id> accountIds = queryAccounts(friendlyIdByAccountId.keySet());

    List<Account> toCreate = new List<Account>();
    Id ownerId = defaultOwnerId();
    for (String accountId : friendlyIdByAccountId.keySet()) {
      if (!accountIds.containsKey(accountId)) {
        // The event has no account name. The friendly ID stands in until enrichment.
        Account account = new Account(
          Name = friendlyIdByAccountId.get(accountId),
          Orders_Account_Id__c = accountId,
          Orders_Friendly_Id__c = friendlyIdByAccountId.get(accountId)
        );
        if (ownerId != null) {
          account.OwnerId = ownerId;
        }
        toCreate.add(account);
      }
    }

    Boolean lostInsertRace = false;
    Map<String, String> errorByAccountId = new Map<String, String>();
    List<Database.SaveResult> saves = Database.insert(toCreate, false, AccessLevel.SYSTEM_MODE);
    for (Integer i = 0; i < saves.size(); i++) {
      if (saves[i].isSuccess()) {
        accountIds.put(toCreate[i].Orders_Account_Id__c, saves[i].getId());
        result.newAccountIds.add(saves[i].getId());
      } else if (isDuplicate(saves[i].getErrors())) {
        lostInsertRace = true;
      } else {
        errorByAccountId.put(
          toCreate[i].Orders_Account_Id__c,
          describe(saves[i].getErrors())
        );
      }
    }
    if (lostInsertRace) {
      accountIds.putAll(queryAccounts(friendlyIdByAccountId.keySet()));
    }

    for (EventItem item : items) {
      if (!accountIds.containsKey(item.payload.accountId)) {
        String error = errorByAccountId.get(item.payload.accountId);
        item.fail(
          'Could not create the account: ' +
          (error == null ? 'concurrent insert conflict.' : error)
        );
      }
    }
    return accountIds;
  }

  private static Map<String, Id> queryAccounts(Set<String> ordersAccountIds) {
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

  /**
   * The rank rule. Locks existing orders so two concurrent events for one order
   * can't both read the old status and overwrite each other.
   *
   * @return items whose new order lost a concurrent insert race and need another pass.
   */
  private static List<EventItem> applyToOrders(
    List<EventItem> items,
    Map<String, Id> accountIds
  ) {
    Map<String, List<EventItem>> itemsByOrderId = new Map<String, List<EventItem>>();
    List<EventItem> ordered = new List<EventItem>();
    for (EventItem item : items) {
      if (item.failed) {
        continue;
      }
      ordered.add(item);
      if (!itemsByOrderId.containsKey(item.payload.orderId)) {
        itemsByOrderId.put(item.payload.orderId, new List<EventItem>());
      }
      itemsByOrderId.get(item.payload.orderId).add(item);
    }
    // Lowest rank first, so a batch holding several events for one order ends on the highest.
    ordered.sort();

    Map<String, External_Order__c> orders = new Map<String, External_Order__c>();
    for (External_Order__c order : [
      SELECT Id, Order_Id__c, Status__c
      FROM External_Order__c
      WHERE Order_Id__c IN :itemsByOrderId.keySet()
      WITH SYSTEM_MODE
      FOR UPDATE
    ]) {
      orders.put(order.Order_Id__c, order);
    }

    Set<String> newOrderIds = new Set<String>();
    Set<String> changedOrderIds = new Set<String>();
    for (EventItem item : ordered) {
      String orderId = item.payload.orderId;
      External_Order__c order = orders.get(orderId);
      if (order == null) {
        order = new External_Order__c(
          Name = item.payload.orderFriendlyId,
          Order_Id__c = orderId,
          Account__c = accountIds.get(item.payload.accountId)
        );
        orders.put(orderId, order);
        newOrderIds.add(orderId);
      }
      if (item.rank > OrderStatuses.rank(order.Status__c)) {
        order.Status__c = item.status;
        order.Status_Changed_At__c = item.payload.occurredAt;
        order.Last_Event_Id__c = item.payload.eventId;
        changedOrderIds.add(orderId);
        item.row.Processing_Status__c = APPLIED;
      } else {
        item.row.Processing_Status__c = STALE;
      }
      item.row.Error__c = null;
    }
    changedOrderIds.removeAll(newOrderIds);

    List<EventItem> conflicted = new List<EventItem>();
    List<External_Order__c> toInsert = pick(orders, newOrderIds);
    List<Database.SaveResult> insertSaves = Database.insert(toInsert, false, AccessLevel.SYSTEM_MODE);
    for (Integer i = 0; i < insertSaves.size(); i++) {
      List<EventItem> affected = itemsByOrderId.get(toInsert[i].Order_Id__c);
      if (insertSaves[i].isSuccess()) {
        continue;
      }
      if (isDuplicate(insertSaves[i].getErrors())) {
        conflicted.addAll(affected);
      } else {
        failAll(affected, describe(insertSaves[i].getErrors()));
      }
      orders.remove(toInsert[i].Order_Id__c);
    }

    List<External_Order__c> toUpdate = pick(orders, changedOrderIds);
    List<Database.SaveResult> updateSaves = Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE);
    for (Integer i = 0; i < updateSaves.size(); i++) {
      if (!updateSaves[i].isSuccess()) {
        failAll(
          itemsByOrderId.get(toUpdate[i].Order_Id__c),
          describe(updateSaves[i].getErrors())
        );
        orders.remove(toUpdate[i].Order_Id__c);
      }
    }

    for (String orderId : orders.keySet()) {
      for (EventItem item : itemsByOrderId.get(orderId)) {
        item.row.Order__c = orders.get(orderId).Id;
      }
    }
    return conflicted;
  }

  private static List<External_Order__c> pick(
    Map<String, External_Order__c> orders,
    Set<String> orderIds
  ) {
    List<External_Order__c> picked = new List<External_Order__c>();
    for (String orderId : orderIds) {
      picked.add(orders.get(orderId));
    }
    return picked;
  }

  private static void failAll(List<EventItem> items, String error) {
    for (EventItem item : items) {
      item.fail(error);
    }
  }

  public static Boolean isDuplicate(List<Database.Error> errors) {
    for (Database.Error error : errors) {
      if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static String describe(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) {
      messages.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(messages, '; ');
  }

  private static Id defaultOwnerId() {
    String ownerId = Orders_Integration_Settings__c.getOrgDefaults()
      .Default_Owner_Id__c;
    return String.isBlank(ownerId) ? null : Id.valueOf(ownerId);
  }

  /** A row with its parsed payload, sortable by lifecycle rank. */
  private class EventItem implements Comparable {
    final Order_Event__c row;
    final OrderEventPayload payload;
    final String status;
    final Integer rank;
    Boolean failed = false;

    EventItem(Order_Event__c row, OrderEventPayload payload) {
      this.row = row;
      this.payload = payload;
      this.status = OrderStatuses.fromEventType(payload.eventType);
      this.rank = OrderStatuses.rank(this.status);
    }

    void fail(String error) {
      failed = true;
      row.Processing_Status__c = OrderEventProcessor.FAILED;
      row.Error__c = error.abbreviate(ERROR_MAX_LENGTH);
      row.Order__c = null;
    }

    public Integer compareTo(Object other) {
      return rank - ((EventItem) other).rank;
    }
  }
}
