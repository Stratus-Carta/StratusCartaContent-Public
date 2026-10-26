@IsTest
private class LockRecordOnceTest {
    private static LockRecordOnce.Request request(Id recordId) {
        LockRecordOnce.Request req = new LockRecordOnce.Request();
        req.recordId = recordId;
        return req;
    }

    @IsTest
    static void locksDuplicateRequestsOnce() {
        Account acc = new Account(Name = 'Lock Record Once Test');
        insert acc;

        Test.startTest();
        List<LockRecordOnce.Result> results = LockRecordOnce.lockOnce(
            new List<LockRecordOnce.Request>{ request(acc.Id), request(acc.Id) }
        );
        Test.stopTest();

        Assert.isTrue(results[0].lockedNow, 'First request should lock the record');
        Assert.isFalse(results[1].lockedNow, 'Duplicate request should not report a new lock');
        Assert.isNull(results[1].errorMessage, 'Duplicate request should not fail');
        Assert.isTrue(Approval.isLocked(acc.Id), 'Record should be locked');
    }

    @IsTest
    static void skipsAlreadyLockedRecord() {
        Account acc = new Account(Name = 'Lock Record Once Test');
        insert acc;
        Approval.lock(acc.Id);

        Test.startTest();
        List<LockRecordOnce.Result> results = LockRecordOnce.lockOnce(
            new List<LockRecordOnce.Request>{ request(acc.Id) }
        );
        Test.stopTest();

        Assert.isFalse(results[0].lockedNow, 'Already locked record should not report a new lock');
    }
}