/**
 * NF_AgentApi
 * Agentforce Agent API (api.salesforce.com/einstein/ai-agent/v1) through the NF_AgentApi named credential:
 * the same client-credentials login as NF_RevenueCloud (NF Revenue Cloud API external client app, which
 * issues JWT tokens with the chatbot_api and sfap_api scopes). Sessions run the NF_Sales_Agent service
 * agent as its agent user (bypassUser). Every call is traced (kind AGENT_API) for the Journey Inspector.
 */
public inherited sharing class NF_AgentApi {

    public static final String AGENT_NAME = 'NF_Sales_Agent';
    @TestVisible private static final String BASE = 'callout:NF_AgentApi/einstein/ai-agent/v1';
    private static final Integer TIMEOUT_MS = 120000;

    /** Test double for the Agent API: returns the response body for a request (status 200). */
    @TestVisible private static NF_RevCloudApi.Responder responder;
    @TestVisible private static String agentIdOverride;

    /** The trace entry of the last call, so the agent's action traces can be shown inside it. */
    public static NF_Trace.Entry lastEntry;

    public class Session {
        public String sessionId;
        public List<String> messages;
    }

    public static Session startSession(String journeyKey) {
        Map<String, Object> body = new Map<String, Object>{
            'externalSessionKey' => journeyKey,
            'instanceConfig' => new Map<String, Object>{ 'endpoint' => URL.getOrgDomainUrl().toExternalForm() },
            'streamingCapabilities' => new Map<String, Object>{ 'chunkTypes' => new List<String>{ 'Text' } },
            'bypassUser' => true,
            'variables' => new List<Object>{
                new Map<String, Object>{ 'name' => 'journey_key', 'type' => 'Text', 'value' => journeyKey }
            }
        };
        Map<String, Object> res = call('POST', '/agents/' + agentId() + '/sessions', body, 'Agentforce · start session', null);
        Session s = new Session();
        s.sessionId = String.valueOf(res.get('sessionId'));
        s.messages = texts(res);
        if (String.isBlank(s.sessionId) || s.sessionId == 'null') {
            throw new NF_JourneyModels.JourneyException('The NovaFiber assistant is not available right now.');
        }
        return s;
    }

    public static List<String> send(String sessionId, Integer sequenceId, String text) {
        Map<String, Object> body = new Map<String, Object>{
            'message' => new Map<String, Object>{ 'sequenceId' => sequenceId, 'type' => 'Text', 'text' => text },
            'variables' => new List<Object>()
        };
        return texts(call('POST', '/sessions/' + sessionId + '/messages', body, 'Agentforce · customer message #' + sequenceId, null));
    }

    public static void endSession(String sessionId) {
        call('DELETE', '/sessions/' + sessionId, null, 'Agentforce · end session',
            new Map<String, String>{ 'x-session-end-reason' => 'UserRequest' });
    }

    public static String agentId() {
        if (agentIdOverride != null) return agentIdOverride;
        List<BotDefinition> bots = [SELECT Id FROM BotDefinition WHERE DeveloperName = :AGENT_NAME LIMIT 1];
        if (bots.isEmpty()) throw new NF_JourneyModels.JourneyException('The NovaFiber assistant is not available right now.');
        return bots[0].Id;
    }

    /** The agent's reply texts (Inform and other text messages), in order. */
    @TestVisible
    private static List<String> texts(Map<String, Object> res) {
        List<String> out = new List<String>();
        if (!(res.get('messages') instanceof List<Object>)) return out;
        for (Object o : (List<Object>) res.get('messages')) {
            if (!(o instanceof Map<String, Object>)) continue;
            Object text = ((Map<String, Object>) o).get('message');
            if (text instanceof String && String.isNotBlank((String) text)) out.add((String) text);
        }
        return out;
    }

    private static Map<String, Object> call(String method, String path, Object body, String label, Map<String, String> headers) {
        NF_Trace.Entry t = NF_Trace.start('AGENT_API', method + ' ' + path, label);
        lastEntry = t;
        if (body != null) NF_Trace.request(t, body);
        String requestBody = body == null ? null : JSON.serialize(body, true);
        Integer status;
        String responseBody;
        if (responder != null) {
            status = 200;
            responseBody = responder.respond(method, path, requestBody);
        } else {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(BASE + path);
            req.setMethod(method);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(TIMEOUT_MS);
            if (headers != null) {
                for (String h : headers.keySet()) req.setHeader(h, headers.get(h));
            }
            if (requestBody != null) req.setBody(requestBody);
            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (CalloutException e) {
                NF_Trace.end(t, 'ERROR', e.getMessage());
                throw new NF_RevCloudApi.RevCloudException('The Agent API is not reachable: ' + e.getMessage());
            }
            status = res.getStatusCode();
            responseBody = res.getBody();
        }
        Object parsed;
        try {
            parsed = String.isBlank(responseBody) ? new Map<String, Object>() : JSON.deserializeUntyped(responseBody);
        } catch (JSONException e) {
            parsed = new Map<String, Object>{ 'raw' => responseBody };
        }
        Boolean ok = status >= 200 && status < 300;
        NF_Trace.end(t, ok ? 'OK' : 'ERROR', 'HTTP ' + status + '\n' + responseBody);
        if (!ok) {
            throw new NF_RevCloudApi.RevCloudException('Agent API ' + path + ' failed (HTTP ' + status + '): '
                + NF_RevCloudApi.firstError(parsed));
        }
        return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : new Map<String, Object>{ 'result' => parsed };
    }
}
