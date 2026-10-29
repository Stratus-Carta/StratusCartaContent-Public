/**
 * NF_JourneyCache
 * Journey modes and the org cache behind them (Platform Cache partition NFJourney).
 *
 *   Cached   — serviceability per address, the catalog preview, offers per technology profile and
 *              carts the configurator already priced are served from the org cache (fast).
 *   Realtime — every step calls the serviceability API and Revenue Cloud live; caches are still
 *              refreshed with the live results, but never read.
 *
 * The org default is NF_Journey_Setting__mdt.Default.Journey_Mode__c; agents and debug visitors switch
 * per session (the mode travels with each call). Content entries carry a generation number, so flush()
 * invalidates all of them at once (e.g. after catalog or price changes). Security-relevant entries
 * (the server's copy of a serviceability result) use their own keys and are kept by flush.
 */
public without sharing class NF_JourneyCache {

    public static final String MODE_CACHED = 'Cached';
    public static final String MODE_REALTIME = 'Realtime';

    public static final Integer TTL_SERVICEABILITY = 3600;
    public static final Integer TTL_CATALOG = 3600;
    public static final Integer TTL_PRICED_CART = 1800;

    private static final String PARTITION = 'local.NFJourney';
    private static final String GENERATION_KEY = 'nfgeneration';

    private static String mode;
    private static Integer generation;
    /** Same-transaction copies; also keeps the journey working when Platform Cache is unavailable. */
    private static Map<String, String> local = new Map<String, String>();

    // ── Mode ─────────────────────────────────────────────────────────────────

    public static void setMode(String requested) {
        mode = requested == MODE_CACHED || requested == MODE_REALTIME ? requested : defaultMode();
    }

    public static String mode() {
        return mode == null ? defaultMode() : mode;
    }

    public static Boolean isRealtime() {
        return mode() == MODE_REALTIME;
    }

    public static String defaultMode() {
        NF_Journey_Setting__mdt s = NF_Journey_Setting__mdt.getInstance('Default');
        return s != null && s.Journey_Mode__c == MODE_REALTIME ? MODE_REALTIME : MODE_CACHED;
    }

    // ── Entries ──────────────────────────────────────────────────────────────

    /** Key for content that flush() invalidates. */
    public static String key(String kind, String identity) {
        return kind + 'g' + generation() + 'x' + digest(identity);
    }

    /** Key that survives flush() (e.g. the server's copy of a serviceability result). */
    public static String stableKey(String kind, String identity) {
        return kind + 'x' + digest(identity);
    }

    /** Cached value, or null in Realtime mode / on a miss. */
    public static String read(String key) {
        return isRealtime() ? null : get(key);
    }

    /** Cached value regardless of mode (for entries the journey relies on, not for speed). */
    public static String get(String key) {
        if (local.containsKey(key)) return local.get(key);
        try {
            Object v = Cache.Org.getPartition(PARTITION).get(key);
            return v == null ? null : (String) v;
        } catch (Exception e) {
            return null;
        }
    }

    public static void put(String key, String value, Integer ttlSeconds) {
        local.put(key, value);
        try {
            Cache.Org.getPartition(PARTITION).put(key, value, ttlSeconds);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'NF journey cache unavailable: ' + e.getMessage());
        }
    }

    /** Invalidates every content entry (new generation). Returns the new generation. */
    public static Integer flush() {
        Integer next = generation() + 1;
        try {
            Cache.Org.getPartition(PARTITION).put(GENERATION_KEY, next, 172800);   // platform maximum: 48 h
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'NF journey cache unavailable: ' + e.getMessage());
        }
        generation = next;
        local.clear();
        return next;
    }

    private static Integer generation() {
        if (generation == null) {
            generation = 1;
            try {
                Object g = Cache.Org.getPartition(PARTITION).get(GENERATION_KEY);
                if (g != null) generation = (Integer) g;
            } catch (Exception e) {
                generation = 1;
            }
        }
        return generation;
    }

    private static String digest(String identity) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(identity == null ? '' : identity)));
    }
}
