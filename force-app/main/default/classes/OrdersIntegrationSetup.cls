/**
 * Post-deploy configuration, called from scripts/apex/setup.apex.
 *
 * A class because anonymous Apex can't use system mode, and the setting's fields
 * have no field permissions granted to anyone on purpose: the secret should not
 * be readable through the UI or API by ordinary users.
 */
public with sharing class OrdersIntegrationSetup {
  /**
   * @param webhookSecret shared secret for verifying Orders-Signature
   * @param defaultOwnerId user who owns records the webhook creates
   */
  public static void configure(String webhookSecret, Id defaultOwnerId) {
    Orders_Integration_Settings__c settings = Orders_Integration_Settings__c.getOrgDefaults();
    settings.Webhook_Secret__c = webhookSecret;
    settings.Default_Owner_Id__c = defaultOwnerId;
    upsert as system settings;
  }
}
