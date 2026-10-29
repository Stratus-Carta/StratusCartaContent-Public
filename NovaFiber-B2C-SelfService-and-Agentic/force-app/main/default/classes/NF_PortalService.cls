/**
 * NF_PortalService
 * "My NovaFiber" customer login for the proof of concept. The org has no Experience Cloud customer licences,
 * so customers get a NovaFiber login (NF_Portal_User__c) instead of a Salesforce user:
 *  - passwords: per-user random salt, ITERATIONS rounds of HMAC-SHA256, only the hash is stored;
 *  - lockout: MAX_FAILURES wrong passwords lock the login for LOCK_MINUTES;
 *  - sessions: 256-bit random token returned to the browser once, only its SHA-256 hash is stored,
 *    sliding SESSION_MINUTES expiry, revoked on logout;
 *  - every read goes through the session's own account: a customer only ever sees their own data.
 * Not a replacement for Salesforce identity in production (no MFA, password reset or email verification).
 */
public without sharing class NF_PortalService {

    public static final Integer ITERATIONS = 2000;
    public static final Integer MAX_FAILURES = 5;
    public static final Integer LOCK_MINUTES = 15;
    public static final Integer SESSION_MINUTES = 120;
    private static final String GENERIC_LOGIN_ERROR = 'That email and password don\'t match our records.';

    public class Session {
        public String token;          // only ever returned once, at login
        public NF_Portal_User__c user;
    }

    // ── Passwords ────────────────────────────────────────────────────────────

    public static void checkPasswordRules(String password) {
        if (String.isBlank(password) || password.length() < 10 || !Pattern.matches('.*[A-Za-z].*', password)
            || !Pattern.matches('.*[0-9].*', password)) {
            throw new NF_JourneyModels.JourneyException('Choose a password of at least 10 characters with letters and numbers.');
        }
        if (password.length() > 128) throw new NF_JourneyModels.JourneyException('That password is too long.');
    }

    @TestVisible
    private static String hash(String password, String salt, Integer iterations) {
        Blob key = Blob.valueOf(password);
        Blob h = Blob.valueOf(salt);
        for (Integer i = 0; i < iterations; i++) h = Crypto.generateMac('hmacSHA256', h, key);
        return EncodingUtil.convertToHex(h);
    }

    private static String randomHex(Integer bits) {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(bits));
    }

    // ── Accounts ─────────────────────────────────────────────────────────────

    /**
     * Creates the customer's login (checkout form). An existing login for the same email keeps its password
     * and is linked to the new order's account and contact. Returns the username.
     */
    public static String register(Id accountId, Id contactId, String email, String password) {
        String username = email == null ? null : email.trim().toLowerCase();
        if (String.isBlank(username)) throw new NF_JourneyModels.JourneyException('An email address is needed for My NovaFiber.');
        List<NF_Portal_User__c> existing = [SELECT Id, Account__c, Contact__c FROM NF_Portal_User__c WHERE Username__c = :username LIMIT 1];
        if (!existing.isEmpty()) {
            NF_Portal_User__c u = existing[0];
            if (accountId != null) u.Account__c = accountId;
            if (contactId != null) u.Contact__c = contactId;
            update u;
            return username;
        }
        checkPasswordRules(password);
        String salt = randomHex(128);
        insert new NF_Portal_User__c(Username__c = username, Account__c = accountId, Contact__c = contactId, Salt__c = salt,
            Iterations__c = ITERATIONS, Password_Hash__c = hash(password, salt, ITERATIONS), Failed_Attempts__c = 0);
        return username;
    }

    /** Links an existing login to the contact created with the order. */
    public static void linkContact(String email, Id accountId, Id contactId) {
        if (String.isBlank(email)) return;
        List<NF_Portal_User__c> us = [SELECT Id FROM NF_Portal_User__c WHERE Username__c = :email.trim().toLowerCase() LIMIT 1];
        if (!us.isEmpty()) update new NF_Portal_User__c(Id = us[0].Id, Account__c = accountId, Contact__c = contactId);
    }

    public static Boolean exists(String email) {
        return String.isNotBlank(email) && [SELECT COUNT() FROM NF_Portal_User__c WHERE Username__c = :email.trim().toLowerCase()] > 0;
    }

    // ── Sessions ─────────────────────────────────────────────────────────────

    public static Session login(String username, String password) {
        String name = username == null ? '' : username.trim().toLowerCase();
        List<NF_Portal_User__c> us = [
            SELECT Id, Username__c, Account__c, Contact__c, Password_Hash__c, Salt__c, Iterations__c, Failed_Attempts__c, Locked_Until__c
            FROM NF_Portal_User__c WHERE Username__c = :name LIMIT 1
        ];
        if (us.isEmpty() || String.isBlank(password)) {
            if (String.isNotBlank(password)) hash(password, randomHex(128), ITERATIONS);   // same work as a real check
            throw new NF_JourneyModels.JourneyException(GENERIC_LOGIN_ERROR);
        }
        NF_Portal_User__c u = us[0];
        if (u.Locked_Until__c != null && u.Locked_Until__c > DateTime.now()) {
            throw new NF_JourneyModels.JourneyException('Too many attempts. Please try again in ' + LOCK_MINUTES + ' minutes.');
        }
        Integer iterations = u.Iterations__c == null ? ITERATIONS : u.Iterations__c.intValue();
        if (hash(password, u.Salt__c, iterations) != u.Password_Hash__c) {
            Integer failures = (u.Failed_Attempts__c == null ? 0 : u.Failed_Attempts__c.intValue()) + 1;
            update new NF_Portal_User__c(Id = u.Id, Failed_Attempts__c = failures >= MAX_FAILURES ? 0 : failures,
                Locked_Until__c = failures >= MAX_FAILURES ? DateTime.now().addMinutes(LOCK_MINUTES) : null);
            throw new NF_JourneyModels.JourneyException(failures >= MAX_FAILURES
                ? 'Too many attempts. Please try again in ' + LOCK_MINUTES + ' minutes.' : GENERIC_LOGIN_ERROR);
        }
        update new NF_Portal_User__c(Id = u.Id, Failed_Attempts__c = 0, Locked_Until__c = null, Last_Login__c = DateTime.now());
        Session s = new Session();
        s.token = randomHex(256);
        s.user = u;
        insert new NF_Portal_Session__c(Portal_User__c = u.Id, Token_Hash__c = tokenHash(s.token),
            Expires_At__c = DateTime.now().addMinutes(SESSION_MINUTES));
        return s;
    }

    /** The logged-in user for a token (sliding expiry); throws when the session is gone. */
    public static NF_Portal_User__c resolve(String token) {
        if (String.isBlank(token) || token.length() != 64) throw new NF_JourneyModels.JourneyException('Please log in.');
        List<NF_Portal_Session__c> ss = [
            SELECT Id, Expires_At__c, Revoked__c, Portal_User__r.Id, Portal_User__r.Username__c, Portal_User__r.Account__c, Portal_User__r.Contact__c
            FROM NF_Portal_Session__c WHERE Token_Hash__c = :tokenHash(token) LIMIT 1
        ];
        if (ss.isEmpty() || ss[0].Revoked__c || ss[0].Expires_At__c < DateTime.now()) {
            throw new NF_JourneyModels.JourneyException('Your session has ended. Please log in again.');
        }
        if (ss[0].Expires_At__c < DateTime.now().addMinutes(SESSION_MINUTES - 5)) {
            update new NF_Portal_Session__c(Id = ss[0].Id, Expires_At__c = DateTime.now().addMinutes(SESSION_MINUTES));
        }
        return ss[0].Portal_User__r;
    }

    public static void logout(String token) {
        if (String.isBlank(token)) return;
        List<NF_Portal_Session__c> ss = [SELECT Id FROM NF_Portal_Session__c WHERE Token_Hash__c = :tokenHash(token) LIMIT 1];
        if (!ss.isEmpty()) update new NF_Portal_Session__c(Id = ss[0].Id, Revoked__c = true);
    }

    private static String tokenHash(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token)));
    }
}
