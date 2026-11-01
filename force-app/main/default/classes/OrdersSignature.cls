/**
 * Verifies Orders-Signature: hex(HMAC-SHA256(secret, raw body bytes)).
 * Takes the body as a Blob because the signature covers the exact bytes sent;
 * re-serializing parsed JSON could change them.
 */
public class OrdersSignature {
  private static final String ALGORITHM = 'hmacSHA256';

  public static Boolean isValid(
    Blob rawBody,
    String hexSignature,
    String secret
  ) {
    if (
      rawBody == null ||
      String.isBlank(hexSignature) ||
      String.isBlank(secret)
    ) {
      return false;
    }
    try {
      return Crypto.verifyHMac(
        ALGORITHM,
        rawBody,
        Blob.valueOf(secret),
        EncodingUtil.convertFromHex(hexSignature.trim())
      );
    } catch (Exception badInput) {
      // Non-hex or wrong-length signatures throw.
      return false;
    }
  }
}
