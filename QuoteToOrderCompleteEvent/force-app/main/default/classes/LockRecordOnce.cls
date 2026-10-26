public with sharing class LockRecordOnce {
    public class Request {
        @InvocableVariable(required=true label='Record Id')
        public Id recordId;
    }

    public class Result {
        @InvocableVariable(label='Locked Now' description='True only for the first request that locked the record in this call. False when it was already locked, repeated in the same batch, or the lock failed.')
        public Boolean lockedNow;

        @InvocableVariable(label='Error Message' description='Lock error, if any.')
        public String errorMessage;
    }

    // Platform event flows run several interviews in one bulk call. When two Orders of the
    // same Quote complete together, both interviews ask to lock the same Quote; the standard
    // Lock Record action then fails with "already in queue to be locked". Locking each record
    // once here keeps the other interviews from failing and from notifying twice.
    @InvocableMethod(label='Lock Record Once' description='Locks each record once per call (Approval.lock) and reports which request locked it.' category='Approvals')
    public static List<Result> lockOnce(List<Request> requests) {
        Set<Id> recordIds = new Set<Id>();
        for (Request req : requests) {
            recordIds.add(req.recordId);
        }

        Map<Id, Boolean> lockedById = Approval.isLocked(new List<Id>(recordIds));
        List<Id> toLock = new List<Id>();
        for (Id recordId : recordIds) {
            if (lockedById.get(recordId) != true) {
                toLock.add(recordId);
            }
        }

        Map<Id, String> errorById = new Map<Id, String>();
        Set<Id> lockedNowIds = new Set<Id>();
        if (!toLock.isEmpty()) {
            List<Approval.LockResult> lockResults = Approval.lock(toLock, false);
            for (Integer i = 0; i < lockResults.size(); i++) {
                if (lockResults[i].isSuccess()) {
                    lockedNowIds.add(toLock[i]);
                } else {
                    errorById.put(toLock[i], lockResults[i].getErrors()[0].getMessage());
                }
            }
        }

        List<Result> results = new List<Result>();
        Set<Id> reported = new Set<Id>();
        for (Request req : requests) {
            Result res = new Result();
            res.lockedNow = lockedNowIds.contains(req.recordId) && reported.add(req.recordId);
            res.errorMessage = errorById.get(req.recordId);
            results.add(res);
        }
        return results;
    }
}