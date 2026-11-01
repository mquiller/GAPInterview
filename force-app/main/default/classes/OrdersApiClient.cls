/**
 * The only class that calls the Orders API. Turns HTTP outcomes into typed errors, so
 * callers can decide per case: NotFound is final, RateLimited says when to retry,
 * Unavailable covers everything else that went wrong on the way.
 *
 * Reads are the only operation: in this integration Salesforce never writes to Orders.
 */
public with sharing class OrdersApiClient {
  private static final String NAMED_CREDENTIAL = 'callout:Orders_API';
  private static final Integer TIMEOUT_MS = 10000;
  private static final Integer DEFAULT_RETRY_AFTER_SECONDS = 60;

  public virtual class OrdersApiException extends Exception {
  }
  public class NotFoundException extends OrdersApiException {
  }
  public class UnavailableException extends OrdersApiException {
  }
  public class RateLimitedException extends OrdersApiException {
    public Integer retryAfterSeconds = DEFAULT_RETRY_AFTER_SECONDS;
  }

  /** @return the account's name, the only field Salesforce keeps from this response. */
  public static String getAccountName(String accountId) {
    Map<String, Object> account = getJson(
      '/accounts/' + EncodingUtil.urlEncode(accountId, 'UTF-8')
    );
    String name = (String) account.get('name');
    if (String.isBlank(name)) {
      throw new UnavailableException('Orders returned an account with no name.');
    }
    return name;
  }

  /** @return the full order, for display only. It is never stored. */
  public static OrderDetails getOrder(String orderId) {
    Map<String, Object> order = getJson(
      '/orders/' + EncodingUtil.urlEncode(orderId, 'UTF-8')
    );
    try {
      return new OrderDetails(order);
    } catch (TypeException e) {
      throw new UnavailableException(
        'Orders returned an unreadable order: ' + e.getMessage()
      );
    }
  }

  private static Map<String, Object> getJson(String path) {
    HttpRequest request = new HttpRequest();
    request.setEndpoint(NAMED_CREDENTIAL + path);
    request.setMethod('GET');
    request.setHeader('Accept', 'application/json');
    request.setTimeout(TIMEOUT_MS);

    HttpResponse response;
    try {
      response = new Http().send(request);
    } catch (CalloutException e) {
      throw new UnavailableException(
        'Could not reach Orders: ' + e.getMessage()
      );
    }

    Integer status = response.getStatusCode();
    if (status == 404) {
      throw new NotFoundException('Orders has no record at ' + path);
    }
    if (status == 429) {
      RateLimitedException limited = new RateLimitedException(
        'Orders rate limit reached.'
      );
      limited.retryAfterSeconds = parseRetryAfter(
        response.getHeader('Retry-After')
      );
      throw limited;
    }
    if (status < 200 || status >= 300) {
      throw new UnavailableException('Orders returned HTTP ' + status);
    }

    try {
      return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    } catch (Exception e) {
      throw new UnavailableException('Orders returned a body that is not a JSON object.');
    }
  }

  private static Integer parseRetryAfter(String header) {
    try {
      Integer seconds = Integer.valueOf(header.trim());
      return seconds > 0 ? seconds : DEFAULT_RETRY_AFTER_SECONDS;
    } catch (Exception missingOrNotANumber) {
      return DEFAULT_RETRY_AFTER_SECONDS;
    }
  }

  /*
   * The parts of GET /orders/{orderId} the LWC shows. Mapped by hand rather than with
   * JSON.deserialize because `currency` is a reserved word in Apex, so no field can
   * carry that name.
   */
  public class OrderDetails {
    @AuraEnabled
    public String participantRef;
    @AuraEnabled
    public Money amount;
    @AuraEnabled
    public List<OrderLine> lines = new List<OrderLine>();

    OrderDetails(Map<String, Object> order) {
      participantRef = (String) order.get('participantRef');
      amount = new Money((Map<String, Object>) order.get('amount'));
      List<Object> rawLines = (List<Object>) order.get('lines');
      if (rawLines != null) {
        for (Object rawLine : rawLines) {
          lines.add(new OrderLine((Map<String, Object>) rawLine));
        }
      }
    }
  }

  public class OrderLine {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public String type;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Money amount;

    OrderLine(Map<String, Object> line) {
      id = (String) line.get('id');
      type = (String) line.get('type');
      status = (String) line.get('status');
      amount = new Money((Map<String, Object>) line.get('amount'));
    }
  }

  public class Money {
    @AuraEnabled
    public String value;
    @AuraEnabled
    public String currencyCode;

    Money(Map<String, Object> money) {
      if (money != null) {
        value = (String) money.get('value');
        currencyCode = (String) money.get('currency');
      }
    }
  }
}
