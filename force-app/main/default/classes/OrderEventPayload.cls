/**
 * Strict parse of an Orders event body. Anything required that is missing or the
 * wrong shape throws InvalidPayloadException, so callers never see a half-valid event.
 * An unknown event type is not rejected here: it is well formed, and deciding what
 * to do with it belongs to the service.
 */
public class OrderEventPayload {
  public class InvalidPayloadException extends Exception {
  }

  public String eventId { get; private set; }
  public String eventType { get; private set; }
  public Datetime occurredAt { get; private set; }
  public String orderId { get; private set; }
  public String orderFriendlyId { get; private set; }
  public String accountId { get; private set; }
  public String accountFriendlyId { get; private set; }

  private OrderEventPayload() {
  }

  public static OrderEventPayload parse(String body) {
    try {
      Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
        body
      );
      Map<String, Object> event = (Map<String, Object>) root.get('event');
      Map<String, Object> data = (Map<String, Object>) root.get('data');

      OrderEventPayload payload = new OrderEventPayload();
      payload.eventId = requiredString(event, 'id');
      payload.eventType = requiredString(event, 'type');
      payload.occurredAt = (Datetime) JSON.deserialize(
        JSON.serialize(requiredString(event, 'occurredAt')),
        Datetime.class
      );
      payload.orderId = requiredString(data, 'orderId');
      payload.orderFriendlyId = requiredString(data, 'orderFriendlyId');
      payload.accountId = requiredString(data, 'accountId');
      payload.accountFriendlyId = requiredString(data, 'accountFriendlyId');
      return payload;
    } catch (InvalidPayloadException e) {
      throw e;
    } catch (Exception e) {
      // Not JSON, wrong shape (TypeException), a missing section (NullPointerException), bad date.
      throw new InvalidPayloadException(
        'Body is not a valid event: ' + e.getMessage()
      );
    }
  }

  private static String requiredString(Map<String, Object> source, String key) {
    String value = (String) source.get(key);
    if (String.isBlank(value)) {
      throw new InvalidPayloadException('Missing required field: ' + key);
    }
    return value;
  }
}
