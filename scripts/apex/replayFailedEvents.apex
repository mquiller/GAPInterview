// Re-runs events marked Failed, oldest first, up to 200 per run.
// Uses the same code path as live delivery. Applied and Stale rows are never touched.
System.debug(LoggingLevel.ERROR, 'SIM replayed ' + OrdersWebhookService.replayFailed() + ' event(s)');
