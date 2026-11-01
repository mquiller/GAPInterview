/**
 * The Orders status lifecycle. Rank is what makes out-of-order delivery safe:
 * the spec says statuses never move backward, so an event only takes effect if
 * it ranks above the order's current status.
 *
 * Assumption: nothing follows `returned`. The spec implies this but doesn't say
 * it directly. See "Questions I would have asked" in the README.
 */
public class OrderStatuses {
  private static final String EVENT_TYPE_PREFIX = 'order.';

  private static final Map<String, Integer> RANK_BY_STATUS = new Map<String, Integer>{
    'created' => 0,
    'inProgress' => 1,
    'waitingForParticipant' => 2,
    'sent' => 3,
    'cleared' => 4,
    'returned' => 5
  };

  /** @return the status an event type sets (order.sent => sent), or null if unknown. */
  public static String fromEventType(String eventType) {
    if (eventType == null || !eventType.startsWith(EVENT_TYPE_PREFIX)) {
      return null;
    }
    String status = eventType.removeStart(EVENT_TYPE_PREFIX);
    return RANK_BY_STATUS.containsKey(status) ? status : null;
  }

  /** @return the status's position in the lifecycle; -1 if blank or unknown, so anything outranks it. */
  public static Integer rank(String status) {
    Integer rank = status == null ? null : RANK_BY_STATUS.get(status);
    return rank == null ? -1 : rank;
  }
}
