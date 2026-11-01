// Sends the spec's five sample events through the real handler, signed with the
// shared secret, then a tampered copy. No Site needed. Run setup.apex first.
//   sf apex run --file scripts/apex/simulateEvents.apex
// Look for the SIM lines in the output. Running it again is safe: everything dedupes.
String secret = 'orders-takehome-2026';

List<String> bodies = new List<String>{
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_001","type":"order.inProgress","occurredAt":"2026-10-10T10:00:00Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}',
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_002","type":"order.waitingForParticipant","occurredAt":"2026-10-11T10:00:00Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}',
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_001","type":"order.inProgress","occurredAt":"2026-10-10T10:00:00Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}',
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_004","type":"order.sent","occurredAt":"2026-10-12T14:03:11Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}',
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_003","type":"order.cleared","occurredAt":"2026-10-09T09:41:27Z","version":"1.0"},"data":{"orderId":"ord_52ab10","orderFriendlyId":"OR-260922-017-1187","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}'
};

for (String body : bodies) {
  Blob raw = Blob.valueOf(body);
  String signature = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', raw, Blob.valueOf(secret)));
  Integer status = OrdersWebhookService.handle(raw, signature);
  System.debug(LoggingLevel.ERROR, 'SIM ' + body.substringBetween('"id":"', '"') + ' -> HTTP ' + status);
}

// Signed for one body, delivered with another: must get a 401 and store nothing.
String original = bodies[0];
String tampered = original.replace('order.inProgress', 'order.returned').replace('evt_001', 'evt_tampered');
String signatureOfOriginal = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(original), Blob.valueOf(secret)));
System.debug(LoggingLevel.ERROR, 'SIM tampered -> HTTP ' + OrdersWebhookService.handle(Blob.valueOf(tampered), signatureOfOriginal));

for (External_Order__c order : [SELECT Name, Order_Id__c, Status__c, Account__r.Name FROM External_Order__c WHERE Account__r.Orders_Account_Id__c = 'acct_8f3c2a' ORDER BY Order_Id__c]) {
  System.debug(LoggingLevel.ERROR, 'SIM order ' + order.Order_Id__c + ' = ' + order.Status__c + ' on ' + order.Account__r.Name);
}
System.debug(LoggingLevel.ERROR, 'SIM rows for evt_001: ' + [SELECT COUNT() FROM Order_Event__c WHERE Event_Id__c = 'evt_001']);
System.debug(LoggingLevel.ERROR, 'SIM rows for evt_tampered: ' + [SELECT COUNT() FROM Order_Event__c WHERE Event_Id__c = 'evt_tampered']);
