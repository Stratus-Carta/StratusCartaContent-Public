// NovaFiber Field Service setup for installation booking (NF_SchedulingService). Idempotent; rerun safe.
//   Work types      NovaFiber Home Installation (3 h), NovaFiber Business Site Installation (4 h)
//   Operating hours one per time zone, Mon–Sat 08:00–18:00
//   Territories     one per priced state (NY, CA, IL, GA, TX, AK), each with install crews (ServiceCrew + crew ServiceResource)
//   Scheduled load  background appointments over the next 3 weeks so the booking calendar shows realistic availability
// Run: sf apex run -f scripts/apex/nf_14_fieldServiceSetup.apex

Boolean RESEED_LOAD = true;

Map<String, Integer> workTypes = new Map<String, Integer>{
    'NovaFiber Home Installation' => 3, 'NovaFiber Business Site Installation' => 4 };
Map<String, WorkType> wtByName = new Map<String, WorkType>();
for (WorkType w : [SELECT Id, Name FROM WorkType WHERE Name IN :workTypes.keySet()]) wtByName.put(w.Name, w);
for (String n : workTypes.keySet()) {
    if (!wtByName.containsKey(n)) {
        WorkType w = new WorkType(Name = n, EstimatedDuration = workTypes.get(n), DurationType = 'Hours',
            Description = n.contains('Business') ? 'Business site survey, fiber or DIA hand-off, edge router and SD-WAN set-up, service turn-up.'
                : 'Fiber drop and ONT install, Wi-Fi gateway set-up and speed test.');
        insert w;
        wtByName.put(n, w);
    }
}

// state => [territory, city, street, zip, time zone, crews]
List<List<String>> territories = new List<List<String>>{
    new List<String>{ 'NY', 'NovaFiber New York Metro', 'New York', '1 Liberty Plaza', '10006', 'America/New_York', '3' },
    new List<String>{ 'CA', 'NovaFiber Bay Area', 'San Francisco', '600 Townsend St', '94103', 'America/Los_Angeles', '2' },
    new List<String>{ 'IL', 'NovaFiber Chicagoland', 'Chicago', '222 W Adams St', '60606', 'America/Chicago', '2' },
    new List<String>{ 'GA', 'NovaFiber Atlanta', 'Atlanta', '191 Peachtree St NE', '30303', 'America/New_York', '2' },
    new List<String>{ 'TX', 'NovaFiber Central Texas', 'Austin', '500 W 2nd St', '78701', 'America/Chicago', '2' },
    new List<String>{ 'AK', 'NovaFiber Alaska', 'Anchorage', '601 W 5th Ave', '99501', 'America/Anchorage', '1' }
};

Map<String, OperatingHours> ohByTz = new Map<String, OperatingHours>();
for (OperatingHours oh : [SELECT Id, Name, TimeZone FROM OperatingHours WHERE Name LIKE 'NovaFiber Install Hours%']) ohByTz.put(oh.TimeZone, oh);
for (List<String> t : territories) {
    String tz = t[5];
    if (ohByTz.containsKey(tz)) continue;
    OperatingHours oh = new OperatingHours(Name = 'NovaFiber Install Hours - ' + tz, TimeZone = tz);
    insert oh;
    List<TimeSlot> slots = new List<TimeSlot>();
    for (String d : new List<String>{ 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }) {
        slots.add(new TimeSlot(OperatingHoursId = oh.Id, DayOfWeek = d, Type = 'Normal',
            StartTime = Time.newInstance(8, 0, 0, 0), EndTime = Time.newInstance(18, 0, 0, 0)));
    }
    insert slots;
    ohByTz.put(tz, oh);
}

Map<String, ServiceTerritory> stByName = new Map<String, ServiceTerritory>();
for (ServiceTerritory st : [SELECT Id, Name FROM ServiceTerritory WHERE Name LIKE 'NovaFiber %']) stByName.put(st.Name, st);
for (List<String> t : territories) {
    if (stByName.containsKey(t[1])) continue;
    ServiceTerritory st = new ServiceTerritory(Name = t[1], OperatingHoursId = ohByTz.get(t[5]).Id, IsActive = true,
        Street = t[3], City = t[2], State = t[0], PostalCode = t[4], Country = 'US',
        Description = 'NovaFiber installation territory for ' + t[0] + '.');
    insert st;
    stByName.put(t[1], st);
}

// An active crew needs at least one technician member, and technicians are users. To use no extra licences,
// the running admin is the "field ops lead" technician on every crew; scheduling books the crews.
Id leadUserId = UserInfo.getUserId();
List<ServiceResource> leads = [SELECT Id FROM ServiceResource WHERE RelatedRecordId = :leadUserId AND ResourceType = 'T' LIMIT 1];
ServiceResource lead = leads.isEmpty()
    ? new ServiceResource(Name = 'NF Field Ops Lead', ResourceType = 'T', RelatedRecordId = leadUserId, IsActive = true) : leads[0];
if (leads.isEmpty()) insert lead;

Map<String, ServiceResource> crewByName = new Map<String, ServiceResource>();
for (ServiceResource r : [SELECT Id, Name FROM ServiceResource WHERE ResourceType = 'C' AND Name LIKE 'NF Install Crew %']) crewByName.put(r.Name, r);
Map<String, ServiceCrew> crewRecByName = new Map<String, ServiceCrew>();
for (ServiceCrew c : [SELECT Id, Name FROM ServiceCrew WHERE Name LIKE 'NF Install Crew %']) crewRecByName.put(c.Name, c);
List<String> crewNames = new List<String>{ 'Alpha', 'Bravo', 'Charlie' };
for (List<String> t : territories) {
    for (Integer i = 0; i < Integer.valueOf(t[6]); i++) {
        String name = 'NF Install Crew ' + t[0] + '-' + crewNames[i];
        if (crewByName.containsKey(name)) continue;
        ServiceCrew crew = crewRecByName.get(name);
        if (crew == null) {
            crew = new ServiceCrew(Name = name, CrewSize = 2);
            insert crew;
        }
        if ([SELECT COUNT() FROM ServiceCrewMember WHERE ServiceCrewId = :crew.Id] == 0) {
            insert new ServiceCrewMember(ServiceCrewId = crew.Id, ServiceResourceId = lead.Id,
                StartDate = DateTime.now().addDays(-1), IsLeader = true);
        }
        ServiceResource r = new ServiceResource(Name = name, ResourceType = 'C', ServiceCrewId = crew.Id, IsActive = true,
            Description = 'Two-technician installation crew, ' + t[2] + '.');
        insert r;
        insert new ServiceTerritoryMember(ServiceResourceId = r.Id, ServiceTerritoryId = stByName.get(t[1]).Id,
            EffectiveStartDate = DateTime.now().addDays(-1), TerritoryType = 'P');
        crewByName.put(name, r);
    }
}

// ── Scheduled load ───────────────────────────────────────────────────────────
List<Account> ops = [SELECT Id FROM Account WHERE Name = 'NovaFiber Field Ops (scheduled load)' LIMIT 1];
Account opsAcc = ops.isEmpty() ? new Account(Name = 'NovaFiber Field Ops (scheduled load)') : ops[0];
if (ops.isEmpty()) insert opsAcc;

if (RESEED_LOAD) {
    delete [SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :opsAcc.Id];
    List<ServiceAppointment> sas = new List<ServiceAppointment>();
    List<Id> crewForSa = new List<Id>();
    Integer[] startHours = new Integer[]{ 8, 10, 13 };
    for (List<String> t : territories) {
        ServiceTerritory st = stByName.get(t[1]);
        Timezone tz = Timezone.getTimeZone(t[5]);
        for (Integer i = 0; i < Integer.valueOf(t[6]); i++) {
            Id crewId = crewByName.get('NF Install Crew ' + t[0] + '-' + crewNames[i]).Id;
            for (Integer d = 1; d <= 21; d++) {
                Date day = Date.today().addDays(d);
                if (DateTime.newInstance(day, Time.newInstance(12, 0, 0, 0)).format('EEEE') == 'Sunday') continue;
                for (Integer h : startHours) {
                    // busier in the first week, lighter later on
                    Decimal busy = d <= 5 ? 0.45 : (d <= 12 ? 0.3 : 0.15);
                    if (Math.random() > busy) continue;
                    DateTime localAsGmt = DateTime.newInstanceGmt(day, Time.newInstance(h, 0, 0, 0));
                    DateTime startUtc = localAsGmt.addSeconds(-tz.getOffset(localAsGmt) / 1000);
                    sas.add(new ServiceAppointment(ParentRecordId = opsAcc.Id, ServiceTerritoryId = st.Id,
                        Subject = 'Scheduled install (existing customer)', Status = 'Scheduled',
                        EarliestStartTime = startUtc, DueDate = startUtc.addHours(4),
                        ArrivalWindowStartTime = startUtc, ArrivalWindowEndTime = startUtc.addHours(2),
                        SchedStartTime = startUtc, SchedEndTime = startUtc.addHours(2),
                        Duration = 2, DurationType = 'Hours', City = t[2], State = t[0], Country = 'US'));
                    crewForSa.add(crewId);
                }
            }
        }
    }
    insert sas;
    List<AssignedResource> ars = new List<AssignedResource>();
    for (Integer i = 0; i < sas.size(); i++) ars.add(new AssignedResource(ServiceAppointmentId = sas[i].Id, ServiceResourceId = crewForSa[i]));
    insert ars;
    System.debug('NF scheduled load: ' + sas.size() + ' appointments');
}
System.debug('NF field service: ' + stByName.size() + ' territories, ' + crewByName.size() + ' crews, work types ' + wtByName.keySet());
