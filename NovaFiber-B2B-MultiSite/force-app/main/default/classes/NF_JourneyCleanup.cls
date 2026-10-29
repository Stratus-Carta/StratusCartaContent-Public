/**
 * NF_JourneyCleanup
 * Removes what abandoned journeys left behind (visitors who closed the page instead of discarding):
 *  - draft journey quotes of prospect accounts untouched for ABANDONED_AFTER_HOURS and never ordered
 *    (their lines, service locations and bundle relationships cascade);
 *  - prospect accounts left without quotes or orders;
 *  - worker requests older than 7 days;
 *  - AI chat journeys (NF_Agent_Journey__c) untouched for ABANDONED_AFTER_HOURS;
 *  - expired or logged-out My NovaFiber sessions.
 * Scheduled hourly (see scripts/apex/nf_03_scheduleCleanup.apex); runs as the scheduling user.
 * Customer accounts picked by agents are never touched: only "NovaFiber Prospect" accounts qualify.
 */
public without sharing class NF_JourneyCleanup implements Schedulable {

    public static final Integer ABANDONED_AFTER_HOURS = 24;
    @TestVisible private static DateTime cutoffOverride;

    public void execute(SchedulableContext sc) {
        run();
    }

    /** Returns how many records were deleted. */
    public static Integer run() {
        DateTime cutoff = cutoffOverride != null ? cutoffOverride : DateTime.now().addHours(-ABANDONED_AFTER_HOURS);
        String prospects = NF_QuoteService.PROSPECT_PREFIX + '%';
        Integer deleted = 0;

        List<Quote> stale = [
            SELECT Id FROM Quote
            WHERE NF_Channel__c != null AND Status = 'Draft' AND QuoteAccount.Name LIKE :prospects
              AND LastModifiedDate < :cutoff
              AND Id NOT IN (SELECT QuoteId FROM Order WHERE QuoteId != null)
            LIMIT 200
        ];
        deleted += countDeleted(Database.delete(stale, false));

        List<Account> orphans = [
            SELECT Id FROM Account
            WHERE Name LIKE :prospects AND CreatedDate < :cutoff
              AND Id NOT IN (SELECT QuoteAccountId FROM Quote WHERE QuoteAccountId != null)
              AND Id NOT IN (SELECT AccountId FROM Order)
            LIMIT 200
        ];
        deleted += countDeleted(Database.delete(orphans, false));

        DateTime weekAgo = cutoffOverride != null ? cutoffOverride : DateTime.now().addDays(-7);
        deleted += countDeleted(Database.delete([SELECT Id FROM NF_Journey_Request__c WHERE CreatedDate < :weekAgo LIMIT 1000], false));
        // AI chat journeys (their draft quotes are removed above like any other journey quote)
        deleted += countDeleted(Database.delete([SELECT Id FROM NF_Agent_Journey__c WHERE LastModifiedDate < :cutoff LIMIT 1000], false));
        // My NovaFiber sessions that expired or were logged out
        deleted += countDeleted(Database.delete([SELECT Id FROM NF_Portal_Session__c
            WHERE Expires_At__c < :DateTime.now() OR (Revoked__c = true AND LastModifiedDate < :cutoff) LIMIT 1000], false));
        System.debug(LoggingLevel.INFO, 'NF journey cleanup deleted ' + deleted + ' record(s)');
        return deleted;
    }

    private static Integer countDeleted(List<Database.DeleteResult> results) {
        Integer n = 0;
        for (Database.DeleteResult r : results) {
            if (r.isSuccess()) {
                n++;
            } else {
                System.debug(LoggingLevel.WARN, 'NF journey cleanup could not delete ' + r.getId() + ': ' + r.getErrors()[0].getMessage());
            }
        }
        return n;
    }
}
