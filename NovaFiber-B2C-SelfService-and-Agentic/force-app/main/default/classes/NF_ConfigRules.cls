/**
 * Reads what the configuration rules (CML constraint models NF_Residential_Rules / NF_Business_Rules) did in a
 * configurator response, so the cart can follow Revenue Cloud:
 *   - options a rule added or removed (require / exclude), as the item's options after the rules ran
 *   - options a rule hides or disables (response uiTreatments), so the configurator stops offering them
 * Lines are matched to cart items through their root node (SalesTrxnItemRelationship.RootItem): rule-added lines
 * get engine ids (ref_...), not ours.
 */
public with sharing class NF_ConfigRules {

    public class Result {
        public List<NF_JourneyModels.RuleAdjustment> adjustments = new List<NF_JourneyModels.RuleAdjustment>();
        public List<NF_JourneyModels.HiddenOption> hidden = new List<NF_JourneyModels.HiddenOption>();
        /** One info message per adjusted item ("Updated by NovaFiber rules: added …; removed …"). */
        public List<NF_JourneyModels.CartMessage> notes = new List<NF_JourneyModels.CartMessage>();
        /** Every line of the response that belongs to a cart item (rule-added ones included) → its root node. */
        public Map<String, String> rootByLine = new Map<String, String>();
        /** Line → its bundle parent line (null for roots). */
        public Map<String, String> parentByLine = new Map<String, String>();
    }

    /**
     * @param lines        SalesTransactionItem maps of the configure response
     * @param uiTreatments the response's uiTreatments
     * @param roots        root node id → the cart item it was built from
     * @param offers       product id → offer (its option groups give component ids)
     */
    public static Result read(List<Map<String, Object>> lines, Object uiTreatments,
                              Map<String, NF_JourneyModels.CartItem> roots, Map<String, NF_JourneyModels.Offer> offers) {
        Result r = new Result();
        Map<String, Map<String, Decimal>> present = new Map<String, Map<String, Decimal>>();
        for (String root : roots.keySet()) present.put(root, new Map<String, Decimal>());

        Map<String, String> parents = new Map<String, String>();
        Map<String, String> rootItems = new Map<String, String>();
        for (Map<String, Object> li : lines) {
            String id = String.valueOf(li.get('id'));
            for (Object rel : asList(li.get('SalesTrxnItemRelationship'))) {
                Map<String, Object> m = asMap(rel);
                if (m.get('RootItem') != null) rootItems.put(id, String.valueOf(m.get('RootItem')));
                if (m.get('MainItem') != null) parents.put(id, String.valueOf(m.get('MainItem')));
            }
        }
        for (Map<String, Object> li : lines) {
            String id = String.valueOf(li.get('id'));
            String parent = parents.get(id);
            String root = rootItems.get(id);
            if (root == null) {
                // no RootItem on the relationship: walk up the bundle parents
                root = id;
                for (Integer guard = 0; parents.containsKey(root) && guard < 10; guard++) root = parents.get(root);
            }
            if (!roots.containsKey(root)) continue;
            r.rootByLine.put(id, root);
            r.parentByLine.put(id, parent);
            if (id == root) continue;
            String productId = String.valueOf(li.get('Product'));
            Decimal qty = li.get('Quantity') == null ? 1 : Decimal.valueOf(String.valueOf(li.get('Quantity')));
            Map<String, Decimal> p = present.get(root);
            p.put(productId, (p.containsKey(productId) ? p.get(productId) : 0) + qty);
        }

        for (String root : roots.keySet()) {
            NF_JourneyModels.CartItem item = roots.get(root);
            NF_JourneyModels.Offer offer = offers.get(item.productId);
            if (offer == null || offer.groups == null) continue;
            Map<String, NF_JourneyModels.Option> chosen = NF_QuoteService.optionsFor(offer, item);
            Map<String, Decimal> now = present.get(root);
            NF_JourneyModels.RuleAdjustment adj = new NF_JourneyModels.RuleAdjustment();
            adj.itemKey = item.key;
            adj.productName = offer.name;
            adj.options = new List<NF_JourneyModels.SelectedOption>();
            adj.added = new List<String>();
            adj.removed = new List<String>();
            Boolean changed = false;
            List<String> changes = new List<String>();
            for (NF_JourneyModels.OptionGroup g : offer.groups) {
                for (NF_JourneyModels.Option op : g.options) {
                    Decimal wanted = chosen.containsKey(op.componentId) ? requestedQty(item, op) : 0;
                    Decimal got = now.containsKey(op.productId) ? now.get(op.productId) : 0;
                    if (got > 0) {
                        NF_JourneyModels.SelectedOption so = new NF_JourneyModels.SelectedOption();
                        so.componentId = op.componentId;
                        so.quantity = got.intValue();
                        adj.options.add(so);
                    }
                    if (wanted == got) continue;
                    changed = true;
                    if (wanted == 0) adj.added.add(got > 1 ? op.name + ' × ' + got.intValue() : op.name);
                    else if (got == 0) adj.removed.add(op.name);
                    else changes.add(op.name + ' to ' + got.intValue());
                }
            }
            if (!changed) continue;
            r.adjustments.add(adj);
            NF_JourneyModels.CartMessage note = new NF_JourneyModels.CartMessage();
            note.itemKey = item.key;
            note.productName = offer.name;
            note.severity = 'info';
            note.category = 'cml';
            List<String> parts = new List<String>();
            if (!adj.added.isEmpty()) parts.add('added ' + String.join(adj.added, ', '));
            if (!adj.removed.isEmpty()) parts.add('removed ' + String.join(adj.removed, ', '));
            if (!changes.isEmpty()) parts.add('set ' + String.join(changes, ', '));
            note.message = 'Updated by NovaFiber configuration rules: ' + String.join(parts, '; ') + '.';
            r.notes.add(note);
        }

        for (Object o : asList(uiTreatments)) {
            Map<String, Object> t = asMap(o);
            String kind = String.valueOf(t.get('uiTreatmentType'));
            Map<String, Object> d = asMap(t.get('details'));
            NF_JourneyModels.CartItem item = roots.get(String.valueOf(d.get('stiId')));
            if (item == null || d.get('prcId') == null || (kind != 'hide' && kind != 'disable')) continue;
            NF_JourneyModels.HiddenOption h = new NF_JourneyModels.HiddenOption();
            h.itemKey = item.key;
            h.componentId = String.valueOf(d.get('prcId'));
            h.treatment = kind;
            r.hidden.add(h);
        }
        if (!r.adjustments.isEmpty() || !r.hidden.isEmpty()) {
            NF_Trace.Entry e = NF_Trace.note('RULE', 'Configuration rules (CML)', r.adjustments.size() + ' item(s) adjusted · '
                + r.hidden.size() + ' option(s) hidden');
            if (e != null) e.responseJson = NF_Trace.toJson(new Map<String, Object>{ 'adjustments' => r.adjustments, 'hidden' => r.hidden });
        }
        return r;
    }

    /**
     * Drops bundle-validation messages of items the rules adjusted: they describe the engine's intermediate lines
     * (e.g. a second seat line), and the cart takes the adjusted options before the next change.
     */
    public static List<NF_JourneyModels.CartMessage> withoutStale(List<NF_JourneyModels.CartMessage> messages, Result r) {
        Set<String> adjusted = new Set<String>();
        for (NF_JourneyModels.RuleAdjustment a : r.adjustments) adjusted.add(a.itemKey);
        List<NF_JourneyModels.CartMessage> out = new List<NF_JourneyModels.CartMessage>();
        for (NF_JourneyModels.CartMessage m : messages) {
            if (m.category == 'bundlevalidation' && adjusted.contains(m.itemKey)) continue;
            if (m.category == 'configurationrules' && m.severity != 'error' && explains(m, r)) continue;
            out.add(m);
        }
        return out;
    }

    /**
     * A rule message about an option the rules just added or removed (e.g. "NovaShield Security comes with a static
     * IP…") becomes part of that item's update note, so the cart shows one message per change.
     */
    private static Boolean explains(NF_JourneyModels.CartMessage m, Result r) {
        for (Integer i = 0; i < r.adjustments.size(); i++) {
            NF_JourneyModels.RuleAdjustment a = r.adjustments[i];
            if (a.itemKey != m.itemKey || m.message == null) continue;
            List<String> names = new List<String>(a.added);
            names.addAll(a.removed);
            for (String n : names) {
                if (m.message.contains(n.substringBefore(' × '))) {
                    for (NF_JourneyModels.CartMessage note : r.notes) {
                        if (note.itemKey == a.itemKey) note.message = note.message.removeEnd('.') + '. ' + m.message;
                    }
                    return true;
                }
            }
        }
        return false;
    }

    private static Decimal requestedQty(NF_JourneyModels.CartItem item, NF_JourneyModels.Option op) {
        Integer q = NF_QuoteService.quantityOf(item, op);
        return q == null || q == 0 ? 1 : q;
    }

    private static List<Object> asList(Object o) {
        return o instanceof List<Object> ? (List<Object>) o : new List<Object>();
    }

    private static Map<String, Object> asMap(Object o) {
        return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
    }
}
