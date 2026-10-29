/**
 * NF_Trace
 * Request-scoped trace of what the journey did on the server: Apex entry points,
 * callouts, Revenue Cloud PST, flows, SOQL and DML — with payloads and the records
 * written or read. Returned to the browser's Journey Inspector when debug is allowed
 * (agents always; guests only when NF_Journey_Setting__mdt.Guest_Debug_Enabled__c).
 *
 * Disabled by default: every call is a cheap no-op unless enable() ran.
 */
public without sharing class NF_Trace {

    public class Rec {
        @AuraEnabled public String op;          // INSERT | UPDATE | DELETE | READ | PST
        @AuraEnabled public String sobjectType;
        @AuraEnabled public String recordId;
        @AuraEnabled public String label;
    }

    public class Entry {
        @AuraEnabled public String id;
        @AuraEnabled public String parentId;
        @AuraEnabled public String kind;        // APEX | CALLOUT | SOQL | DML | PST | FLOW | EVENT | WORKER
        @AuraEnabled public String label;
        @AuraEnabled public String detail;
        @AuraEnabled public String status = 'OK';
        @AuraEnabled public Long startedAt;
        @AuraEnabled public Integer durationMs;
        @AuraEnabled public String requestJson;
        @AuraEnabled public String responseJson;
        @AuraEnabled public List<Rec> records = new List<Rec>();
    }

    private static Boolean enabled = false;
    private static List<Entry> entries = new List<Entry>();
    private static List<Entry> open = new List<Entry>();
    private static Integer seq = 0;

    public static void enable() { enabled = true; }
    public static Boolean isEnabled() { return enabled; }

    /** Opens a nested step. Close it with end(). Returns null when tracing is off. */
    public static Entry start(String kind, String label, String detail) {
        if (!enabled) return null;
        Entry e = new Entry();
        seq++;
        e.id = 't' + seq;
        e.parentId = open.isEmpty() ? null : open[open.size() - 1].id;
        e.kind = kind;
        e.label = label;
        e.detail = detail;
        e.startedAt = DateTime.now().getTime();
        entries.add(e);
        open.add(e);
        return e;
    }

    public static void end(Entry e, String status, Object response) {
        if (e == null) return;
        e.durationMs = Integer.valueOf(DateTime.now().getTime() - e.startedAt);
        if (status != null) e.status = status;
        if (response != null) e.responseJson = toJson(response);
        Integer i = open.indexOf(e);
        if (i >= 0) {
            while (open.size() > i) open.remove(open.size() - 1);
        }
    }

    public static void request(Entry e, Object payload) {
        if (e != null && payload != null) e.requestJson = toJson(payload);
    }

    /** One-shot step (no nesting), e.g. a SOQL summary or an event publish. */
    public static Entry note(String kind, String label, String detail) {
        Entry e = start(kind, label, detail);
        end(e, null, null);
        return e;
    }

    /** Records a DML/PST/READ against the innermost open step (or a new DML step). */
    public static void rec(String op, SObject so, String label) {
        if (!enabled || so == null) return;
        rec(op, String.valueOf(so.getSObjectType()), so.Id, label);
    }

    public static void rec(String op, String sobjectType, Id recordId, String label) {
        if (!enabled) return;
        Rec r = new Rec();
        r.op = op;
        r.sobjectType = sobjectType;
        r.recordId = recordId;
        r.label = label;
        Entry target = open.isEmpty() ? note('DML', op + ' ' + sobjectType, null) : open[open.size() - 1];
        target.records.add(r);
    }

    /** One DML (or READ) step with the affected rows, e.g. dml('INSERT', new List<SObject>{acc}, 'prospect'). */
    public static void dml(String op, List<SObject> rows, String label) {
        if (!enabled || rows == null || rows.isEmpty()) return;
        String type = String.valueOf(rows[0].getSObjectType());
        Entry e = start(op == 'READ' ? 'SOQL' : 'DML', op + ' ' + type + (rows.size() > 1 ? ' ×' + rows.size() : ''), label);
        for (SObject so : rows) {
            Rec r = new Rec();
            r.op = op;
            r.sobjectType = type;
            r.recordId = so.Id;
            r.label = label;
            e.records.add(r);
        }
        end(e, null, null);
    }

    public static List<Entry> drain() {
        List<Entry> out = entries;
        entries = new List<Entry>();
        open = new List<Entry>();
        return out;
    }

    /** Appends entries captured in another transaction (the async worker). */
    public static void absorb(List<Entry> others) {
        if (enabled && others != null) entries.addAll(others);
    }

    public static Map<String, Integer> limitsSnapshot() {
        return new Map<String, Integer>{
            'soql' => Limits.getQueries(),
            'dml' => Limits.getDmlStatements(),
            'callouts' => Limits.getCallouts(),
            'cpuMs' => Limits.getCpuTime()
        };
    }

    // ── Payload hygiene ──────────────────────────────────────────────────────

    // Anchored at the start of a run (lookbehind) and possessive, so matching stays linear on long
    // tokens; otherwise large payloads hit Apex's "Regex too complicated" limit.
    private static final Pattern EMAIL = Pattern.compile('(?<![A-Za-z0-9._%+\\-])([A-Za-z0-9._%+\\-])[A-Za-z0-9._%+\\-]*+@([A-Za-z0-9.\\-]++)');
    private static final Pattern SECRET = Pattern.compile('("(?:NF_Booking_Token__c|bookingToken)"\\s*:\\s*")[^"]*(")');
    private static final Pattern PHONE = Pattern.compile('(?<![\\d+])(\\+?\\d[\\d ()\\-.]{6,}\\d)(\\d{2})');

    private static final Integer MAX_PAYLOAD = 20000;

    public static String toJson(Object o) {
        String s = o instanceof String ? (String) o : JSON.serializePretty(o, true);
        // Cap before masking: regex over large Revenue Cloud payloads hits "Regex too complicated".
        if (s.length() <= MAX_PAYLOAD) return mask(s);
        return mask(s.left(MAX_PAYLOAD)) + '\n… truncated (' + s.length() + ' chars)';
    }

    /** Masks emails, phone numbers and booking tokens so traces are safe to show. */
    public static String mask(String s) {
        if (s == null) return null;
        s = EMAIL.matcher(s).replaceAll('$1***@$2');
        s = PHONE.matcher(s).replaceAll('***-***-**$2');
        s = SECRET.matcher(s).replaceAll('$1••••••$2');
        return s;
    }
}
