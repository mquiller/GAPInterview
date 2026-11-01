/**
 * Replaces the placeholder name on Accounts the webhook just created. Events carry no
 * account name, and the callout can't run inside the webhook request: the sender only
 * waits 10 seconds, and Apex can't call out after DML in the same transaction.
 *
 * Spends the 60 requests/minute budget carefully: one call per new account, ever. On a
 * 429 it waits as told. A failure here never affects order status: the Account keeps
 * its friendly ID as its name and stays fully usable.
 *
 * Without sharing, explicit system mode: enqueued by the webhook, so it runs as the Site
 * guest user, who has no record access.
 */
public without sharing class AccountEnrichmentJob implements Queueable, Database.AllowsCallouts {
  private static final Integer MAX_ATTEMPTS = 3;
  private static final Integer MAX_DELAY_MINUTES = 10;

  @TestVisible
  private static Integer scheduledDelayMinutes;

  private final Set<Id> accountIds;
  private final Integer attempt;

  public AccountEnrichmentJob(Set<Id> accountIds) {
    this(accountIds, 1);
  }

  private AccountEnrichmentJob(Set<Id> accountIds, Integer attempt) {
    this.accountIds = accountIds;
    this.attempt = attempt;
  }

  public void execute(QueueableContext context) {
    Set<Id> remaining = new Set<Id>(accountIds);
    List<Account> toUpdate = new List<Account>();
    List<Integration_Error__c> errors = new List<Integration_Error__c>();
    Integer retryAfterSeconds = null;
    Integer callLimit = Limits.getLimitCallouts();

    for (Account account : [
      SELECT Id, Orders_Account_Id__c
      FROM Account
      WHERE Id IN :accountIds
      WITH SYSTEM_MODE
    ]) {
      if (Limits.getCallouts() >= callLimit) {
        break;
      }
      try {
        toUpdate.add(
          new Account(
            Id = account.Id,
            Name = OrdersApiClient.getAccountName(account.Orders_Account_Id__c)
          )
        );
        remaining.remove(account.Id);
      } catch (OrdersApiClient.RateLimitedException e) {
        retryAfterSeconds = e.retryAfterSeconds;
        break;
      } catch (OrdersApiClient.OrdersApiException e) {
        // 404 or unavailable: nothing a quick retry would fix. Keep the placeholder.
        remaining.remove(account.Id);
        errors.add(
          IntegrationErrorLog.build(
            IntegrationErrorLog.ENRICHMENT,
            'Account ' + account.Id + ' keeps its placeholder name: ' + e.getMessage(),
            null
          )
        );
      }
    }

    // Callouts are done, so DML is allowed now.
    for (Database.SaveResult save : Database.update(
      toUpdate,
      false,
      AccessLevel.SYSTEM_MODE
    )) {
      if (!save.isSuccess()) {
        errors.add(
          IntegrationErrorLog.build(
            IntegrationErrorLog.ENRICHMENT,
            'Account name update failed: ' + save.getErrors(),
            null
          )
        );
      }
    }
    IntegrationErrorLog.save(errors);

    continueWith(remaining, retryAfterSeconds);
  }

  private void continueWith(Set<Id> remaining, Integer retryAfterSeconds) {
    if (remaining.isEmpty()) {
      return;
    }
    if (retryAfterSeconds == null) {
      // Out of callouts for this transaction, not rate limited: carry on straight away.
      enqueue(new AccountEnrichmentJob(remaining, attempt), 0);
    } else if (attempt < MAX_ATTEMPTS) {
      Decimal minutes = Decimal.valueOf(retryAfterSeconds) / 60;
      Integer delayMinutes = Math.min(
        MAX_DELAY_MINUTES,
        Math.max(1, minutes.round(System.RoundingMode.CEILING).intValue())
      );
      enqueue(new AccountEnrichmentJob(remaining, attempt + 1), delayMinutes);
    } else {
      IntegrationErrorLog.record(
        IntegrationErrorLog.ENRICHMENT,
        'Gave up after ' + MAX_ATTEMPTS + ' rate-limited attempts: ' + remaining,
        null
      );
    }
  }

  private static void enqueue(AccountEnrichmentJob job, Integer delayMinutes) {
    scheduledDelayMinutes = delayMinutes;
    // Apex tests can't chain Queueables, so tests assert on the recorded delay instead.
    if (!Test.isRunningTest()) {
      System.enqueueJob(job, delayMinutes);
    }
  }
}
