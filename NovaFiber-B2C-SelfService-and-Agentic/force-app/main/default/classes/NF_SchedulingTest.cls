@IsTest
private class NF_SchedulingTest {

    @TestSetup
    static void setup() {
        // A technician must be a user with a Field Service licence; the crew needs one member to be active.
        Profile prof = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User techUser = new User(LastName = 'Tech', Alias = 'nftech', Email = 'nf.tech@example.com',
            Username = 'nf.tech.' + DateTime.now().getTime() + '@example.com', ProfileId = prof.Id,
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        insert techUser;
        List<PermissionSetLicense> psl = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'FieldServiceStandardPsl' LIMIT 1];
        if (!psl.isEmpty()) insert new PermissionSetLicenseAssign(AssigneeId = techUser.Id, PermissionSetLicenseId = psl[0].Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            OperatingHours oh = new OperatingHours(Name = 'NovaFiber Install Hours - test', TimeZone = 'America/New_York');
            insert oh;
            ServiceTerritory st = new ServiceTerritory(Name = 'NovaFiber Test Metro', OperatingHoursId = oh.Id, IsActive = true, State = 'NY');
            insert st;
            insert new WorkType(Name = NF_SchedulingService.HOME_WORK_TYPE, EstimatedDuration = 3, DurationType = 'Hours');

            ServiceResource tech = new ServiceResource(Name = 'Tech', ResourceType = 'T', RelatedRecordId = techUser.Id, IsActive = true);
            insert tech;
            List<ServiceResource> crews = new List<ServiceResource>();
            for (String n : new List<String>{ 'NF Install Crew NY-Alpha', 'NF Install Crew NY-Bravo' }) {
                ServiceCrew c = new ServiceCrew(Name = n, CrewSize = 2);
                insert c;
                insert new ServiceCrewMember(ServiceCrewId = c.Id, ServiceResourceId = tech.Id, StartDate = DateTime.now().addDays(-1), IsLeader = true);
                crews.add(new ServiceResource(Name = n, ResourceType = 'C', ServiceCrewId = c.Id, IsActive = true));
            }
            insert crews;
            List<ServiceTerritoryMember> members = new List<ServiceTerritoryMember>();
            for (ServiceResource r : crews) {
                members.add(new ServiceTerritoryMember(ServiceResourceId = r.Id, ServiceTerritoryId = st.Id,
                    EffectiveStartDate = DateTime.now().addDays(-1), TerritoryType = 'P'));
            }
            insert members;

            Account acc = new Account(Name = 'Jamie Rivera');
            insert acc;
            insert new Order(AccountId = acc.Id, EffectiveDate = Date.today(), Status = 'Draft', NF_Booking_Token__c = 'tok123',
                ShippingStreet = '350 5th Ave', ShippingCity = 'New York', ShippingState = 'NY', ShippingPostalCode = '10001');
        }
    }

    static NF_JourneyModels.JourneyContext visitor() {
        NF_JourneyModels.JourneyContext c = new NF_JourneyModels.JourneyContext();
        c.isAgent = false;
        return c;
    }

    @IsTest
    static void bookingAndReschedulingUseCrewCalendars() {
        NF_SchedulingService.todayOverride = Date.newInstance(2030, 3, 4);   // a Monday
        Order o = [SELECT Id FROM Order LIMIT 1];

        NF_JourneyModels.InstallCalendar cal = NF_SchedulingService.slots(o.Id, 'tok123', null, visitor());
        Assert.areEqual(12, cal.days.size(), 'two working weeks');
        Assert.areEqual(2, cal.crews);
        Assert.areEqual('Thu', cal.days[0].weekday, 'three days lead time');
        Assert.areEqual('8–10 AM', cal.days[0].slots[0].label);
        Assert.areEqual(2, cal.days[0].slots[0].available);
        for (NF_JourneyModels.SlotDay d : cal.days) Assert.areNotEqual('Sun', d.weekday);

        String slot = cal.days[0].slots[0].slotKey;
        NF_JourneyModels.InstallAppointment a = NF_SchedulingService.book(o.Id, 'tok123', 'main', slot, visitor());
        Assert.areEqual('Scheduled', a.status);
        Assert.areEqual('8–10 AM EST', a.windowLabel);
        Assert.isNotNull(a.crewName);

        cal = NF_SchedulingService.slots(o.Id, 'tok123', 'main', visitor());
        Assert.areEqual(2, cal.days[0].slots[0].available, 'the visitor\'s own appointment never blocks a reschedule');

        Order other = new Order(AccountId = [SELECT AccountId FROM Order WHERE Id = :o.Id].AccountId, EffectiveDate = Date.today(),
            Status = 'Draft', NF_Booking_Token__c = 'tok456', ShippingCity = 'Albany', ShippingState = 'NY');
        insert other;
        NF_JourneyModels.InstallCalendar otherCal = NF_SchedulingService.slots(other.Id, 'tok456', 'main', visitor());
        Assert.areEqual(1, otherCal.days[0].slots[0].available, 'one crew left in the booked window');
        Assert.areEqual(1, otherCal.days[0].slots[1].available, 'a 3-hour job overlaps the next window');
        Assert.areEqual(2, otherCal.days[0].slots[2].available);

        // reschedule: same work order and appointment, new window
        NF_JourneyModels.InstallAppointment moved = NF_SchedulingService.book(o.Id, 'tok123', 'main', cal.days[2].slots[2].slotKey, visitor());
        Assert.areEqual(a.appointmentId, moved.appointmentId);
        Assert.areEqual(a.workOrderId, moved.workOrderId);
        Assert.areEqual('1–3 PM EST', moved.windowLabel);
        Assert.areEqual(1, [SELECT COUNT() FROM WorkOrder]);
        Assert.areEqual(1, [SELECT COUNT() FROM AssignedResource]);

        List<NF_JourneyModels.InstallSite> sites = NF_SchedulingService.sites(o.Id, 'tok123', visitor());
        Assert.areEqual(1, sites.size());
        Assert.areEqual(moved.appointmentId, sites[0].appointment.appointmentId);
    }

    @IsTest
    static void novaListsAndBooksInstallWindows() {
        NF_SchedulingService.todayOverride = Date.newInstance(2030, 3, 4);
        Order o = [SELECT Id, OrderNumber FROM Order LIMIT 1];
        NF_AgentJourney.State s = new NF_AgentJourney.State();
        s.order = new NF_JourneyModels.OrderResult();
        s.order.orderId = o.Id;
        s.order.orderNumber = o.OrderNumber;
        s.order.bookingToken = 'tok123';
        insert new NF_Agent_Journey__c(Journey_Key__c = 'jk-install', State__c = JSON.serialize(s));

        NF_AgentActionInstallSlots.Request lr = new NF_AgentActionInstallSlots.Request();
        lr.journeyKey = 'jk-install';
        lr.partOfDay = 'afternoon';
        lr.fromDate = '2030-03-08';
        NF_AgentActionInstallSlots.Result listed = NF_AgentActionInstallSlots.run(new List<NF_AgentActionInstallSlots.Request>{ lr })[0];
        Assert.isTrue(listed.success, listed.summary);
        Assert.isTrue(listed.summary.contains('Fri Mar 8, 1–3 PM EST'), listed.summary);
        Assert.isFalse(listed.summary.contains('8–10 AM'), 'afternoon only');
        String slotKey = listed.summary.substringBetween('(slot key ', ')');

        NF_AgentActionBookInstall.Request br = new NF_AgentActionBookInstall.Request();
        br.journeyKey = 'jk-install';
        br.slotKey = slotKey;
        NF_AgentActionBookInstall.Result booked = NF_AgentActionBookInstall.run(new List<NF_AgentActionBookInstall.Request>{ br })[0];
        Assert.isTrue(booked.success, booked.summary);
        Assert.isTrue(booked.summary.startsWith('Installation booked: Friday, Mar 8'), booked.summary);
        Assert.areEqual('done', booked.step);

        NF_AgentJourney.State after = NF_AgentJourney.load('jk-install').state;
        Assert.isNotNull(after.appointment.appointmentId);
        Assert.isTrue(NF_AgentJourney.status(NF_AgentJourney.load('jk-install')).contains('Installation booked'));
    }

    @IsTest
    static void novaCannotBookBeforeTheOrder() {
        insert new NF_Agent_Journey__c(Journey_Key__c = 'jk-none', State__c = JSON.serialize(new NF_AgentJourney.State()));
        NF_AgentActionBookInstall.Request br = new NF_AgentActionBookInstall.Request();
        br.journeyKey = 'jk-none';
        br.slotKey = '2030-03-08T18:00:00Z';
        NF_AgentActionBookInstall.Result r = NF_AgentActionBookInstall.run(new List<NF_AgentActionBookInstall.Request>{ br })[0];
        Assert.isFalse(r.success);
        Assert.isTrue(r.summary.contains('not placed yet'));
    }

    @IsTest
    static void visitorsNeedTheBookingToken() {
        Order o = [SELECT Id FROM Order LIMIT 1];
        try {
            NF_SchedulingService.slots(o.Id, 'wrong', null, visitor());
            Assert.fail('wrong token must be rejected');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.areEqual('We could not find your order.', e.getMessage());
        }
        NF_JourneyModels.JourneyContext agent = visitor();
        agent.isAgent = true;
        Assert.isNotNull(NF_SchedulingService.slots(o.Id, null, null, agent));
        try {
            NF_SchedulingService.book(o.Id, 'tok123', 'main', '2001-01-01T08:00:00Z', visitor());
            Assert.fail('windows outside the calendar are refused');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('not available'));
        }
    }

    @IsTest
    static void controllerEndpointsAndUnservedStates() {
        Order o = [SELECT Id FROM Order LIMIT 1];
        NF_JourneyModels.Envelope env = NF_JourneyController.getInstallSites(o.Id, 'tok123', false);
        Assert.isNull(env.error);
        env = NF_JourneyController.getInstallSlots(o.Id, 'tok123', 'main', false);
        Assert.isNull(env.error);
        env = NF_JourneyController.bookInstall(o.Id, 'tok123', 'main', 'not-a-date', false);
        Assert.areEqual('Please pick an arrival window.', env.error);

        update new Order(Id = o.Id, ShippingState = 'WY');
        env = NF_JourneyController.getInstallSlots(o.Id, 'tok123', 'main', false);
        Assert.isTrue(env.error.contains('not available in WY'));
        Assert.areEqual('10 AM–12 PM', NF_SchedulingService.windowLabel(10));
    }
}
