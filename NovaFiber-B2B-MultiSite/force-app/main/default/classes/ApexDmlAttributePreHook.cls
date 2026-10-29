/**
 * ApexDmlAttributePreHook
 * Pricing pre-hook that gives every sales transaction line the state of its service location, so the
 * pricing procedure can price by state.
 *
 * Where it runs
 *   Procedure Plan "QuoteProcedure" (Setup → Procedure Plans), section 1, before the pricing procedure
 *   Rev_Mgmt_Default_Pricing_Procedure in section 2. Revenue Cloud calls execute() every time it prices a
 *   quote (Place Sales Transaction, Reprice, configurator sessions) or an order.
 *
 * What it does
 *   1. Reads every SalesTransactionItem in the pricing context (Context Service).
 *   2. Takes each line's recipient (tag ItemSalesTransactionRecipient = QuoteLineItemRecipient or
 *      OrderItemRecipient id) and loads that recipient's ServiceState.
 *   3. Writes the state into the line's context attribute ItemLocationState__c.
 *   The procedure's Location Based Price step then looks up LocationBasedDecisionTable (ItemLocationPrice__c)
 *   by product + ItemLocationState__c; with no matching row the price book entry price applies.
 *
 * Rules
 *   - The recipient must be a real record id: the hook queries it, so "@{ref}" placeholders resolve to nothing.
 *   - Lines being deleted, and lines the configurator marks other than New / Changed, are left alone.
 *   - A line whose recipient has no state keeps whatever ItemLocationState__c it already had.
 *   - A failed state write is logged and pricing continues (those lines get price book prices); a failure to
 *     read the pricing context stops pricing, so it is never silently priced without states.
 *
 * Set DEBUG = true to log each line's recipient, state and the update payload (costly: off by default).
 */
global class ApexDmlAttributePreHook implements RevSignaling.SignalingApexProcessor {

    @TestVisible private static Boolean DEBUG = false;

    private static final String ITEM_TAG = 'SalesTransactionItem';
    private static final String ITEM_RECIPIENT_TAG = 'ItemSalesTransactionRecipient';
    private static final String ITEM_STATE_ATTR = 'ItemLocationState__c';

    private static final String QUOTE_RECIPIENT_PREFIX = QuoteLineItemRecipient.SObjectType.getDescribe().getKeyPrefix();
    private static final String ORDER_RECIPIENT_PREFIX = OrderItemRecipient.SObjectType.getDescribe().getKeyPrefix();

    /** Context Service access; tests replace it with a fake. */
    @TestVisible private static ContextGateway gateway = new IndustriesContextGateway();

    public RevSignaling.TransactionResponse execute(RevSignaling.TransactionRequest request) {
        String contextId = request == null ? null : request.ctxInstanceId;

        // 1. Lines in the pricing context
        List<LineInfo> lines = parseLines(gateway.queryItems(contextId));

        // 2. ServiceState of each line's recipient
        Set<Id> recipientIds = new Set<Id>();
        for (LineInfo l : lines) {
            if (l.recipientId != null) recipientIds.add(l.recipientId);
        }
        Map<Id, String> stateByRecipient = loadStates(recipientIds);

        // 3. ItemLocationState__c for the lines whose state is missing or different
        List<Map<String, Object>> updates = buildUpdates(lines, stateByRecipient);
        if (!updates.isEmpty()) {
            try {
                gateway.updateAttributes(contextId, updates);
            } catch (Exception e) {
                // As before: a failed write doesn't block pricing; those lines get price book prices.
                System.debug(LoggingLevel.ERROR, 'ApexDmlAttributePreHook: updating ' + ITEM_STATE_ATTR + ' failed: '
                    + e.getTypeName() + ': ' + e.getMessage());
            }
        }
        System.debug(LoggingLevel.INFO, 'ApexDmlAttributePreHook: ' + lines.size() + ' line(s), '
            + stateByRecipient.size() + ' recipient state(s), ' + updates.size() + ' line(s) updated');

        RevSignaling.TransactionResponse res = new RevSignaling.TransactionResponse();
        res.status = RevSignaling.TransactionStatus.SUCCESS;
        return res;
    }

    // ── Steps ────────────────────────────────────────────────────────────────

    /** One SalesTransactionItem from the context, reduced to what the hook needs. */
    @TestVisible
    private class LineInfo {
        String itemId;
        List<Object> nodePath;      // context data path without the root context id
        Id recipientId;             // null when missing or not a record id
        String currentState;        // ItemLocationState__c already on the line
        Boolean updatable;
    }

    /**
     * Context items → LineInfo. Each item looks like
     *   { dataPath: [contextId, transactionId, itemId], cfgStatus, actionCode,
     *     tagValue: { ItemSalesTransactionRecipient: { tagValue: id }, ItemLocationState__c: { tagValue: 'NY' } } }
     */
    @TestVisible
    private static List<LineInfo> parseLines(List<Object> items) {
        List<LineInfo> out = new List<LineInfo>();
        if (items == null) return out;
        for (Object o : items) {
            Map<String, Object> item = (Map<String, Object>) o;
            List<Object> dataPath = (List<Object>) item.get('dataPath');
            if (dataPath == null || dataPath.size() < 3) continue;   // not a line node

            LineInfo l = new LineInfo();
            l.itemId = String.valueOf(dataPath[2]);
            l.nodePath = new List<Object>(dataPath);
            l.nodePath.remove(0);

            Map<String, Object> tags = (Map<String, Object>) item.get('tagValue');
            String recipient = tagValue(tags, ITEM_RECIPIENT_TAG);
            l.recipientId = toId(recipient);
            l.currentState = tagValue(tags, ITEM_STATE_ATTR);

            // Lines being deleted are skipped; a null configuration status counts as a new line.
            String cfgStatus = (String) item.get('cfgStatus');
            String actionCode = (String) item.get('actionCode');
            l.updatable = (actionCode == null || !actionCode.equalsIgnoreCase('Delete'))
                && (cfgStatus == null || cfgStatus.equalsIgnoreCase('New') || cfgStatus.equalsIgnoreCase('Changed'));

            if (DEBUG) {
                System.debug('line ' + l.itemId + ' recipient=' + recipient + ' state=' + l.currentState
                    + ' cfgStatus=' + cfgStatus + ' actionCode=' + actionCode + ' updatable=' + l.updatable);
            }
            out.add(l);
        }
        return out;
    }

    /** ServiceState per recipient id; only the object the ids belong to is queried (quote or order recipients). */
    @TestVisible
    private static Map<Id, String> loadStates(Set<Id> recipientIds) {
        Map<Id, String> out = new Map<Id, String>();
        Set<Id> quoteRecipients = new Set<Id>();
        Set<Id> orderRecipients = new Set<Id>();
        for (Id i : recipientIds) {
            String prefix = String.valueOf(i).left(3);
            if (prefix == QUOTE_RECIPIENT_PREFIX) quoteRecipients.add(i);
            else if (prefix == ORDER_RECIPIENT_PREFIX) orderRecipients.add(i);
        }
        if (!quoteRecipients.isEmpty()) {
            for (QuoteLineItemRecipient r : [SELECT Id, ServiceState FROM QuoteLineItemRecipient
                                             WHERE Id IN :quoteRecipients AND ServiceState != null]) {
                out.put(r.Id, r.ServiceState);
            }
        }
        if (!orderRecipients.isEmpty()) {
            for (OrderItemRecipient r : [SELECT Id, ServiceState FROM OrderItemRecipient
                                         WHERE Id IN :orderRecipients AND ServiceState != null]) {
                out.put(r.Id, r.ServiceState);
            }
        }
        return out;
    }

    /** Context attribute updates: ItemLocationState__c for updatable lines whose recipient state is new to them. */
    @TestVisible
    private static List<Map<String, Object>> buildUpdates(List<LineInfo> lines, Map<Id, String> stateByRecipient) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (LineInfo l : lines) {
            if (!l.updatable || l.recipientId == null) continue;
            String state = stateByRecipient.get(l.recipientId);
            if (state == null || state == l.currentState) continue;   // no state to set, or already set
            out.add(new Map<String, Object>{
                'nodePath' => new Map<String, Object>{ 'dataPath' => l.nodePath },
                'attributes' => new List<Object>{
                    new Map<String, Object>{ 'attributeName' => ITEM_STATE_ATTR, 'attributeValue' => state }
                }
            });
        }
        if (DEBUG) System.debug('updates = ' + JSON.serializePretty(out));
        return out;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static String tagValue(Map<String, Object> tags, String tag) {
        if (tags == null || !(tags.get(tag) instanceof Map<String, Object>)) return null;
        Object v = ((Map<String, Object>) tags.get(tag)).get('tagValue');
        return v == null ? null : String.valueOf(v);
    }

    /** A record id, or null for blanks and "@{ref}" placeholders. */
    @TestVisible
    private static Id toId(String value) {
        if (String.isBlank(value)) return null;
        try {
            return Id.valueOf(value);
        } catch (StringException e) {
            return null;
        }
    }

    // ── Context Service ──────────────────────────────────────────────────────

    @TestVisible
    private interface ContextGateway {
        List<Object> queryItems(String contextId);
        void updateAttributes(String contextId, List<Map<String, Object>> updates);
    }

    private class IndustriesContextGateway implements ContextGateway {
        public List<Object> queryItems(String contextId) {
            Map<String, Object> out = new Context.IndustriesContext().queryTags(new Map<String, Object>{
                'contextId' => contextId,
                'tags' => new List<String>{ ITEM_TAG }
            });
            Map<String, Object> result = (Map<String, Object>) out.get('queryResult');
            return result == null ? null : (List<Object>) result.get(ITEM_TAG);
        }
        public void updateAttributes(String contextId, List<Map<String, Object>> updates) {
            new Context.IndustriesContext().updateContextAttributes(new Map<String, Object>{
                'contextId' => contextId,
                'nodePathAndAttributes' => updates
            });
        }
    }
}
