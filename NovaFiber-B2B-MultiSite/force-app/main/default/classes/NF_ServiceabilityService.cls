/**
 * NF_ServiceabilityService
 * Custom serviceability API (not part of Revenue Cloud). Calls the network
 * inventory mock via the NF_Serviceability named credential:
 *   POST callout:NF_Serviceability/nf/serviceability?postalCode={postalCode}
 * and normalises the response into NF_JourneyModels.ServiceabilityResult.
 */
public inherited sharing class NF_ServiceabilityService {

    @TestVisible private static final String ENDPOINT = 'callout:NF_Serviceability/nf/serviceability';
    private static final Integer TIMEOUT_MS = 10000;

    public static NF_JourneyModels.ServiceabilityResult check(NF_JourneyModels.Address address) {
        validate(address);

        // Cached journey: the same address within the hour is answered from the org cache.
        String addressKey = NF_JourneyCache.key('svcaddr', (address.street + '|' + address.unit + '|' + address.city + '|'
            + address.state + '|' + address.postalCode).toLowerCase().normalizeSpace());
        String hit = NF_JourneyCache.read(addressKey);
        if (hit != null) {
            NF_JourneyModels.ServiceabilityResult cached = (NF_JourneyModels.ServiceabilityResult)
                JSON.deserialize(hit, NF_JourneyModels.ServiceabilityResult.class);
            cached.address = address;
            NF_Trace.note('CACHE', 'Serviceability from cache', 'postal code ' + address.postalCode + ' · '
                + cached.serviceabilityId + ' (TTL ' + NF_JourneyCache.TTL_SERVICEABILITY + 's)');
            remember(cached);
            return cached;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT + '?postalCode=' + EncodingUtil.urlEncode(address.postalCode.trim(), 'UTF-8'));
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(address));

        NF_Trace.Entry t = NF_Trace.start('CALLOUT', 'POST callout:NF_Serviceability',
            req.getEndpoint().substringAfter('callout:NF_Serviceability'));
        NF_Trace.request(t, address);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            NF_Trace.end(t, 'ERROR', e.getMessage());
            throw new NF_JourneyModels.JourneyException(
                'We could not reach our network availability service. Please try again in a moment.');
        }
        NF_Trace.end(t, res.getStatusCode() == 200 ? 'OK' : 'ERROR', 'HTTP ' + res.getStatusCode() + '\n' + res.getBody());
        if (res.getStatusCode() != 200) {
            throw new NF_JourneyModels.JourneyException(
                'Our network availability service returned an error (HTTP ' + res.getStatusCode() + '). Please try again.');
        }

        NF_JourneyModels.ServiceabilityResult result;
        try {
            result = (NF_JourneyModels.ServiceabilityResult) JSON.deserialize(
                res.getBody(), NF_JourneyModels.ServiceabilityResult.class);
        } catch (JSONException e) {
            throw new NF_JourneyModels.JourneyException(
                'Our network availability service returned an unexpected response. Please try again.');
        }
        if (result.technologies == null) result.technologies = new List<NF_JourneyModels.Technology>();
        if (result.tvAvailable == null) result.tvAvailable = false;
        result.address = address;
        result.overridden = false;
        remember(result);
        NF_JourneyCache.put(addressKey, JSON.serialize(result), NF_JourneyCache.TTL_SERVICEABILITY);
        return result;
    }

    // ── Server copy of issued results ────────────────────────────────────────
    // The browser carries the result through the journey; the cart and the quote use the copy the
    // server issued (org cache, 30 min), so an edited browser copy has no effect and saving a quote
    // doesn't need to call the network again.

    private static final Integer SERVER_COPY_TTL = 1800;

    private static String serverCopyKey(NF_JourneyModels.ServiceabilityResult r) {
        if (r == null || String.isBlank(r.serviceabilityId) || r.address == null) return null;
        return NF_JourneyCache.stableKey('svc', r.serviceabilityId + '|' + r.address.street + '|' + r.address.unit + '|' + r.address.postalCode);
    }

    public static void remember(NF_JourneyModels.ServiceabilityResult r) {
        String key = serverCopyKey(r);
        if (key != null) NF_JourneyCache.put(key, JSON.serialize(r), SERVER_COPY_TTL);
    }

    /** The result the server issued for this check, or null when it has expired / was never issued. */
    public static NF_JourneyModels.ServiceabilityResult recall(NF_JourneyModels.ServiceabilityResult client) {
        String key = serverCopyKey(client);
        String payload = key == null ? null : NF_JourneyCache.get(key);
        return payload == null ? null
            : (NF_JourneyModels.ServiceabilityResult) JSON.deserialize(payload, NF_JourneyModels.ServiceabilityResult.class);
    }

    /**
     * Agent override: treat the address as serviceable for fiber + 5G even when
     * the network says otherwise (e.g. a new build the inventory has not caught up with).
     */
    public static NF_JourneyModels.ServiceabilityResult overrideResult(NF_JourneyModels.ServiceabilityResult original) {
        NF_JourneyModels.ServiceabilityResult r = original;
        r.status = 'SERVICEABLE';
        // Its own id: the address's regular result (possibly cached for other visitors) stays as it is.
        if (r.serviceabilityId != null && !r.serviceabilityId.endsWith('-OVR')) r.serviceabilityId += '-OVR';
        r.overridden = true;
        r.tvAvailable = true;
        r.message = 'Serviceability overridden by agent ' + UserInfo.getName() + '.';
        r.technologies = new List<NF_JourneyModels.Technology>{
            tech('Fiber', 2000, 2000, 'New Build', 14),
            tech('5G FWA', 250, 30, 'Self Install', 2)
        };
        remember(r);
        return r;
    }

    private static NF_JourneyModels.Technology tech(String name, Integer down, Integer up, String install, Integer lead) {
        NF_JourneyModels.Technology t = new NF_JourneyModels.Technology();
        t.technology = name;
        t.maxDownloadMbps = down;
        t.maxUploadMbps = up;
        t.installType = install;
        t.leadTimeDays = lead;
        return t;
    }

    private static void validate(NF_JourneyModels.Address a) {
        if (a == null || String.isBlank(a.street) || String.isBlank(a.city)
            || String.isBlank(a.state) || String.isBlank(a.postalCode)) {
            throw new NF_JourneyModels.JourneyException('Please enter the street, city, state and ZIP code.');
        }
        if (!Pattern.matches('\\d{5}(-\\d{4})?', a.postalCode.trim())) {
            throw new NF_JourneyModels.JourneyException('Please enter a valid 5-digit ZIP code.');
        }
        if (String.isBlank(a.country)) a.country = 'US';
    }
}
