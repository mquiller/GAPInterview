/**
 * Live order details for the orderLiveDetails LWC. Nothing returned here is stored.
 *
 * Checks the user can see the order before calling out. The callout is not subject to
 * Salesforce sharing, so without this anyone with class access could read any order.
 */
public with sharing class OrderDetailsController {
  @AuraEnabled
  public static OrdersApiClient.OrderDetails getLiveDetails(Id externalOrderId) {
    String ordersOrderId = visibleOrdersOrderId(externalOrderId);
    if (ordersOrderId == null) {
      throw userError('You do not have access to this order.');
    }

    try {
      return OrdersApiClient.getOrder(ordersOrderId);
    } catch (OrdersApiClient.NotFoundException e) {
      throw userError('Orders has no record of this order.');
    } catch (OrdersApiClient.RateLimitedException e) {
      throw userError(
        'Orders is busy. Try again in ' + e.retryAfterSeconds + ' seconds.'
      );
    } catch (OrdersApiClient.OrdersApiException e) {
      System.debug(LoggingLevel.WARN, 'Live order read failed: ' + e.getMessage());
      throw userError(
        'Orders is unavailable right now, so amount, lines and participant can\'t be loaded. The status on this page is the last one Salesforce received and may not be the latest.'
      );
    }
  }

  /** @return null if the user can't see the record, or has no access to the object at all. */
  private static String visibleOrdersOrderId(Id externalOrderId) {
    try {
      List<External_Order__c> visible = [
        SELECT Order_Id__c
        FROM External_Order__c
        WHERE Id = :externalOrderId
        WITH USER_MODE
      ];
      return visible.isEmpty() ? null : visible[0].Order_Id__c;
    } catch (QueryException noObjectAccess) {
      return null;
    }
  }

  private static AuraHandledException userError(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}
