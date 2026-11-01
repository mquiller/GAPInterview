// Look for the SIM lines in the output. Running it again is safe: everything dedupes.
String secret = 'orders-takehome-2026';

List<String> bodies = new List<String>{
  '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":{"id":"evt_006","type":"order.returned","occurredAt":"2026-10-10T10:00:00Z","version":"1.0"},"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231","accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}'
};

for (String body : bodies) {
  Blob raw = Blob.valueOf(body);
  String signature = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', raw, Blob.valueOf(secret)));
  Integer status = OrdersWebhookService.handle(raw, signature);
  System.debug(LoggingLevel.ERROR, 'SIM ' + body.substringBetween('"id":"', '"') + ' -> HTTP ' + status);
}
