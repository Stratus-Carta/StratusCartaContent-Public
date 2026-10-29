// NovaFiber DRO integration definitions (Setup > Integration Definitions): one per mock-system call, all
// served by the NF_DroCalloutProvider Apex provider. IntegrationProviderDef can't be inserted with Apex DML,
// so they are created over the REST API (NF_RevenueCloud named credential). Idempotent. Run before nf_07_droConfig.
Id providerClass = [SELECT Id FROM ApexClass WHERE Name = 'NF_DroCalloutProvider' LIMIT 1].Id;
Map<String, List<String>> defs = new Map<String, List<String>>{
    // developer name => system, path, step name, callback event, label
    'NF_Provisioning_Reserve' => new List<String>{ 'Provisioning', '/provisioning/v1/reservations', 'Reserve network port', 'RESERVED', 'NF NovaNet Provisioning - Reserve Port' },
    'NF_Provisioning_Activate' => new List<String>{ 'Provisioning', '/provisioning/v1/activations', 'Activate service', 'ACTIVATED', 'NF NovaNet Provisioning - Activate Service' },
    'NF_Logistics_Ship' => new List<String>{ 'Logistics', '/logistics/v1/shipments', 'Ship equipment', 'SHIPPED', 'NF NovaShip Logistics - Ship Equipment' },
    'NF_Billing_Account' => new List<String>{ 'Billing', '/billing/v1/accounts', 'Create billing account', '', 'NF NovaBill - Create Billing Account' },
    'NF_Billing_Subscription' => new List<String>{ 'Billing', '/billing/v1/subscriptions', 'Start subscription billing', 'BILLING_STARTED', 'NF NovaBill - Start Subscription Billing' }
};
Set<String> existing = new Set<String>();
for (IntegrationProviderDef d : [SELECT DeveloperName FROM IntegrationProviderDef WHERE DeveloperName IN :defs.keySet()]) existing.add(d.DeveloperName);
Integer created = 0;
for (String dev : defs.keySet()) {
    if (existing.contains(dev)) continue;
    List<String> v = defs.get(dev);
    Map<String, Object> res = NF_RevCloudApi.post('/sobjects/IntegrationProviderDef', new Map<String, Object>{
        'DeveloperName' => dev, 'MasterLabel' => v[4], 'Type' => 'Apex', 'ApexClassId' => providerClass, 'IsActive' => true,
        'CanUseInIntegrationOrch' => true, 'StorePayload' => 'PersistPayload', 'Language' => 'en_US',
        'Description' => 'NovaFiber DRO callout to the mock ' + v[0] + ' system (NF_DroCalloutProvider).' }, 'integration definition ' + dev);
    String defId = String.valueOf(res.get('id'));
    List<List<String>> attrs = new List<List<String>>{
        new List<String>{ 'NF_System', 'System', v[0] }, new List<String>{ 'NF_Path', 'Path', v[1] },
        new List<String>{ 'NF_Step_Name', 'Step Name', v[2] }, new List<String>{ 'NF_Callback_Delay_Minutes', 'Callback Delay Minutes', '1' } };
    if (String.isNotBlank(v[3])) {
        attrs.add(new List<String>{ 'NF_Callback_Event', 'Callback Event', v[3] });
        attrs.add(new List<String>{ 'Callback_URL', 'Callback URL', NF_DroCalloutProvider.CALLBACK_PATH });
    }
    for (List<String> at : attrs) {
        NF_RevCloudApi.post('/sobjects/IntegrationProviderAttr', new Map<String, Object>{
            'IntegrationProviderDefId' => defId, 'DeveloperName' => at[0], 'MasterLabel' => at[1], 'StringValue' => at[2],
            'DataType' => 'String', 'IsRequired' => at[0] == 'NF_System' || at[0] == 'NF_Path' }, 'attribute ' + at[0]);
    }
    created++;
}
System.debug('INTEGRATION DEFS created=' + created + ' existing=' + existing.size());
