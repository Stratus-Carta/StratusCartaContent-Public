@IsTest
private class NF_ConfigRulesTest {

    private static NF_JourneyModels.Option option(String componentId, String productId, String name) {
        NF_JourneyModels.Option op = new NF_JourneyModels.Option();
        op.componentId = componentId;
        op.productId = productId;
        op.name = name;
        op.isQuantityEditable = false;
        op.defaultQuantity = 1;
        return op;
    }

    private static Map<String, Object> line(String id, String productId, String mainItem, String rootItem) {
        Map<String, Object> li = new Map<String, Object>{ 'id' => id, 'Product' => productId, 'Quantity' => 1 };
        if (mainItem != null) {
            Map<String, Object> rel = new Map<String, Object>{ 'MainItem' => mainItem };
            if (rootItem != null) rel.put('RootItem', rootItem);
            li.put('SalesTrxnItemRelationship', new List<Object>{ rel });
        }
        return li;
    }

    /** NovaFiber 2 Gig with Self-Install: the rules swap it for Professional Installation and hide Self-Install. */
    @IsTest
    static void followsRequireAndExclude() {
        NF_JourneyModels.Offer offer = new NF_JourneyModels.Offer();
        offer.productId = 'P2G';
        offer.name = 'NovaFiber 2 Gig';
        NF_JourneyModels.OptionGroup equipment = new NF_JourneyModels.OptionGroup();
        equipment.options = new List<NF_JourneyModels.Option>{ option('C_RTR', 'P_RTR', 'Wi-Fi 6 Router') };
        NF_JourneyModels.OptionGroup install = new NF_JourneyModels.OptionGroup();
        install.options = new List<NF_JourneyModels.Option>{
            option('C_PRO', 'P_PRO', 'Professional Installation'), option('C_SELF', 'P_SELF', 'Self-Install Kit') };
        offer.groups = new List<NF_JourneyModels.OptionGroup>{ equipment, install };

        NF_JourneyModels.CartItem item = new NF_JourneyModels.CartItem();
        item.key = 'item1';
        item.productId = 'P2G';
        item.quantity = 1;
        item.options = new List<NF_JourneyModels.SelectedOption>();
        for (String c : new List<String>{ 'C_RTR', 'C_SELF' }) {
            NF_JourneyModels.SelectedOption so = new NF_JourneyModels.SelectedOption();
            so.componentId = c;
            so.quantity = 1;
            item.options.add(so);
        }

        List<Map<String, Object>> lines = new List<Map<String, Object>>{
            line('T1', 'P2G', null, null),
            line('T1c1', 'P_RTR', 'T1', null),                 // ours, no RootItem: found through the parent
            line('ref_abc', 'P_PRO', 'T1', 'T1')              // added by a require rule
        };                                                    // T1c2 (Self-Install) was removed by an exclude rule
        Object treatments = new List<Object>{ new Map<String, Object>{ 'uiTreatmentType' => 'hide',
            'details' => new Map<String, Object>{ 'stiId' => 'T1', 'prcId' => 'C_SELF' } } };

        Test.startTest();
        NF_ConfigRules.Result r = NF_ConfigRules.read(lines, treatments,
            new Map<String, NF_JourneyModels.CartItem>{ 'T1' => item }, new Map<String, NF_JourneyModels.Offer>{ 'P2G' => offer });
        Test.stopTest();

        Assert.areEqual(1, r.adjustments.size());
        NF_JourneyModels.RuleAdjustment a = r.adjustments[0];
        Assert.areEqual('item1', a.itemKey);
        Assert.areEqual(new List<String>{ 'Professional Installation' }, a.added);
        Assert.areEqual(new List<String>{ 'Self-Install Kit' }, a.removed);
        Set<String> now = new Set<String>();
        for (NF_JourneyModels.SelectedOption so : a.options) now.add(so.componentId);
        Assert.areEqual(new Set<String>{ 'C_RTR', 'C_PRO' }, now);
        Assert.areEqual(1, r.notes.size());
        Assert.areEqual('cml', r.notes[0].category);
        Assert.isTrue(r.notes[0].message.contains('Professional Installation'));
        Assert.areEqual(1, r.hidden.size());
        Assert.areEqual('C_SELF', r.hidden[0].componentId);
        Assert.areEqual('T1', r.rootByLine.get('ref_abc'));
        Assert.areEqual('T1', r.parentByLine.get('T1c1'));

        // A rule message about the added option joins the update note; an unrelated tip stays on its own.
        NF_JourneyModels.CartMessage why = new NF_JourneyModels.CartMessage();
        why.itemKey = 'item1';
        why.severity = 'info';
        why.category = 'configurationrules';
        why.message = 'Professional Installation is included with NovaFiber 2 Gig.';
        NF_JourneyModels.CartMessage tip = new NF_JourneyModels.CartMessage();
        tip.itemKey = 'item1';
        tip.severity = 'info';
        tip.category = 'configurationrules';
        tip.message = 'Tip: add a Wi-Fi mesh extender.';
        List<NF_JourneyModels.CartMessage> kept = NF_ConfigRules.withoutStale(new List<NF_JourneyModels.CartMessage>{ why, tip }, r);
        Assert.areEqual(1, kept.size());
        Assert.areEqual(tip, kept[0]);
        Assert.isTrue(r.notes[0].message.endsWith('Professional Installation is included with NovaFiber 2 Gig.'));
    }

    @IsTest
    static void noChangeNoAdjustment() {
        NF_JourneyModels.Offer offer = new NF_JourneyModels.Offer();
        offer.productId = 'P1';
        offer.name = 'Plan';
        NF_JourneyModels.OptionGroup g = new NF_JourneyModels.OptionGroup();
        g.options = new List<NF_JourneyModels.Option>{ option('C1', 'PC1', 'Router') };
        offer.groups = new List<NF_JourneyModels.OptionGroup>{ g };
        NF_JourneyModels.CartItem item = new NF_JourneyModels.CartItem();
        item.key = 'k';
        item.productId = 'P1';
        item.quantity = 1;
        NF_JourneyModels.SelectedOption so = new NF_JourneyModels.SelectedOption();
        so.componentId = 'C1';
        item.options = new List<NF_JourneyModels.SelectedOption>{ so };

        NF_ConfigRules.Result r = NF_ConfigRules.read(
            new List<Map<String, Object>>{ line('N1', 'P1', null, null), line('N1c1', 'PC1', 'N1', 'N1') }, null,
            new Map<String, NF_JourneyModels.CartItem>{ 'N1' => item }, new Map<String, NF_JourneyModels.Offer>{ 'P1' => offer });
        Assert.isTrue(r.adjustments.isEmpty());
        Assert.isTrue(r.hidden.isEmpty());
        Assert.isTrue(r.notes.isEmpty());
    }
}
