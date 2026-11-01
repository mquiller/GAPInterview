/**
 * POST /services/apexrest/orders/events
 *
 * Thin HTTP adapter. It takes no typed parameters on purpose: the signature covers the
 * raw bytes, so the body has to be read before anything deserializes it. The rules live
 * in OrdersWebhookService. This class touches no records, so it stays `with sharing`.
 */
@RestResource(urlMapping='/orders/events')
global with sharing class OrdersWebhookResource {
  private static final String SIGNATURE_HEADER = 'Orders-Signature';

  @HttpPost
  global static void receive() {
    RestRequest request = RestContext.request;
    Integer statusCode = OrdersWebhookService.handle(
      request.requestBody,
      headerValue(request, SIGNATURE_HEADER)
    );

    RestResponse response = RestContext.response;
    response.statusCode = statusCode;
    response.addHeader('Content-Type', 'application/json');
    // Deliberately says nothing about why a request failed.
    response.responseBody = Blob.valueOf(
      '{"accepted":' + (statusCode == OrdersWebhookService.OK) + '}'
    );
  }

  private static String headerValue(RestRequest request, String name) {
    for (String key : request.headers.keySet()) {
      if (key.equalsIgnoreCase(name)) {
        return request.headers.get(key);
      }
    }
    return null;
  }
}
