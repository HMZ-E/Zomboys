import XCTest

final class ZomboysUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDenseHerdAnimationAndOverviewSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting","--uitesting-run","--uitesting-speed=1","--uitesting-profile","--uitesting-view=herd3d"]
        app.launch()
        XCTAssertTrue(app.buttons["command.pause"].waitForExistence(timeout:20))
        app.buttons["Zoom out"].tap()
        app.buttons["Zoom out"].tap()
        settleScene(seconds:2)
        attachScreenshot("V8 dense herd retains articulated bodies and distant dots",app:app)
        settleScene(seconds:12)
        app.buttons["command.pause"].tap()
        XCTAssertTrue(app.buttons["command.resume"].waitForExistence(timeout:5))
        attachScreenshot("V8 paused crowd preserves poses",app:app)
        app.buttons["Whole city overview"].tap()
        settleScene(seconds:1)
        attachScreenshot("V8 city overview retains compact crowd dots",app:app)
        XCTAssertTrue(app.otherElements["command.map"].exists)
    }

    @MainActor
    func testDrawSafeZoneShowsPaidStreetClosures() throws {
        let app = launchOperation(city: "settat")
        app.buttons["category.infrastructure"].tap()
        app.buttons["tool.safeZone"].tap()
        drawMap(app, from: CGVector(dx: 0.40, dy: 0.43), to: CGVector(dx: 0.62, dy: 0.56))
        let protected = app.staticTexts["map.sheltered"]
        XCTAssertTrue(protected.waitForExistence(timeout: 5), "Drawing a valid district must purchase real street closures and create a protected-area report.")
        XCTAssertGreaterThan(deployedCount(in: app), 0)
        XCTAssertTrue(protected.label.contains("1 ZONE"))
        attachScreenshot("V7 paid district safe zone and street walls", app: app)
        app.buttons["tool.gate"].tap()
        XCTAssertTrue(app.buttons["tool.gate"].isSelected)
        app.buttons["command.start"].tap()
        settleScene(seconds: 2)
        app.buttons["command.pause"].tap()
        XCTAssertTrue(protected.exists)
        attachScreenshot("V7 protected district while paused", app: app)
    }

    @MainActor
    func testCityOutbreakBriefingMinesC4AndRespec() throws {
        let app = launchOperation(city: "settat")
        app.buttons["command.city"].tap()
        app.buttons["operations.mode.cityOutbreak"].tap()
        XCTAssertTrue(app.buttons["operations.stage.neighborhood"].exists)
        XCTAssertTrue(app.buttons["operations.stage.district"].exists)
        let city = app.buttons["operations.city.settat"]
        let content = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 200 }
        for _ in 0..<5 where !city.isHittable { content?.swipeUp() }
        XCTAssertTrue(city.isHittable)
        city.tap()
        XCTAssertTrue(app.buttons["command.start"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["OUTBREAK LOCATION UNKNOWN"].exists)
        XCTAssertFalse(app.buttons["map.arrivals"].exists)
        assertDeployed(0, in: app)
        app.buttons["command.loadout"].tap()
        let upgrade = app.buttons["upgrade.squad"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        upgrade.tap()
        let respec = app.buttons["loadout.respec"]
        XCTAssertTrue(respec.exists)
        respec.tap()
        app.buttons["Close"].tap()
        app.buttons["category.infrastructure"].tap()
        XCTAssertTrue(app.buttons["tool.safeZone"].exists)
        XCTAssertTrue(app.buttons["tool.gate"].exists)
        let tray = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height < 100 }
        let charge = app.buttons["tool.c4"]
        for _ in 0..<3 where !charge.isHittable { tray?.swipeLeft() }
        XCTAssertTrue(charge.isHittable)
        charge.tap()
        tapMap(app, x: 0.55, y: 0.48)
        assertDeployed(1, in: app)
        tapMap(app, x: 0.55, y: 0.48)
        XCTAssertTrue(app.buttons["unit.detonate"].exists)
        XCTAssertFalse(app.buttons["unit.detonate"].isEnabled)
        app.buttons["command.start"].tap()
        waitForInfected(in: app, minimum: 18)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["unit.detonate"])], timeout: 8), .completed)
        app.buttons["command.pause"].tap()
        XCTAssertTrue(app.buttons["unit.detonate"].isEnabled)
        attachScreenshot("V7 city outbreak and remote C4", app: app)
        app.buttons["unit.detonate"].tap()
        assertDeployed(0, in: app)
        XCTAssertTrue(app.staticTexts["command.collateral"].waitForExistence(timeout: 5))
        attachScreenshot("V7 city outbreak collateral", app: app)
    }

    @MainActor
    func testSettatDefaultLandmarksExteriorHerdAndDestruction() throws {
        let app = launchOperation(city:nil)
        XCTAssertTrue(app.buttons["command.city"].label.contains("SETTAT"))
        attachScreenshot("V6 Settat compact 3D city", app:app)
        app.buttons["map.arrivals"].tap()
        let track = app.buttons["map.herd.0.track"]
        XCTAssertTrue(track.waitForExistence(timeout:5))
        XCTAssertTrue(track.label.contains("INFECTED"))
        track.tap()
        for _ in 0..<2 { app.buttons["Zoom in"].tap() }
        settleScene(seconds:0.5)
        attachScreenshot("V6 preassembled large exterior herd dots", app:app)
        app.buttons["map.landmarks"].tap()
        let kasbah = app.buttons["KASBAH ISMAILIA"]
        XCTAssertTrue(kasbah.waitForExistence(timeout:5))
        kasbah.tap()
        for _ in 0..<3 { app.buttons["Zoom in"].tap() }
        settleScene(seconds:0.7)
        attachScreenshot("V6 Settat Kasbah 3D landmark", app:app)
        app.buttons["category.air"].tap()
        app.buttons["tool.b2"].tap()
        app.buttons["command.start"].tap()
        app.buttons["command.speed"].tap(); app.buttons["command.speed"].tap()
        XCTAssertTrue(app.staticTexts["3 SORTIES"].waitForExistence(timeout:30),"Air support must finish its initial mobilization before a paid strike.")
        tapMap(app,x:0.5,y:0.46)
        assertDeployed(1,in:app)
        let collateral = app.staticTexts["command.collateral"]
        XCTAssertTrue(collateral.waitForExistence(timeout:30),"A paid B-2 strike should demolish buildings in its blast area.")
        settleScene(seconds:1.3)
        app.buttons["command.pause"].tap()
        attachScreenshot("V6 Settat bomb damage persistent rubble", app:app)
        app.buttons["Whole city overview"].tap()
        settleScene(seconds:0.5)
        attachScreenshot("V6 compact whole-city dots and ruins", app:app)
        app.buttons["Reset map camera"].tap()
        XCTAssertTrue(collateral.exists,"Changing camera detail must preserve structural destruction.")
    }

    @MainActor
    func testCasablanca3DLandmarksAndWholeCityOverview() throws {
        let app = launchOperation()
        XCTAssertTrue(app.buttons["command.city"].label.contains("CASABLANCA"))
        XCTAssertTrue(app.otherElements["command.map"].label.contains("3D tactical map"))
        XCTAssertTrue(app.descendants(matching: .any)["command.arrival"].exists)
        attachScreenshot("Casablanca native 3D district", app: app)
        let landmarks = app.buttons["map.landmarks"]
        if !landmarks.isHittable {
            print("LANDMARK MENU DIAGNOSTIC: exists=\(landmarks.exists) frame=\(landmarks.frame)\n\(app.debugDescription)")
            let hierarchy = XCTAttachment(string:app.debugDescription)
            hierarchy.name = "Casablanca landmark menu accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertTrue(landmarks.isHittable)

        app.buttons["map.landmarks"].tap()
        let mosque = app.buttons["HASSAN II MOSQUE"]
        XCTAssertTrue(mosque.waitForExistence(timeout: 5))
        mosque.tap()
        for _ in 0..<4 { app.buttons["Zoom in"].tap() }
        settleScene(seconds: 1)
        attachScreenshot("Hassan II Mosque 3D landmark", app: app)
        app.buttons["Toggle 3D camera"].tap()
        attachScreenshot("Hassan II Mosque tilted 3D landmark", app: app)
        app.buttons["Toggle 3D camera"].tap()

        app.buttons["map.landmarks"].tap()
        app.buttons["TWIN CENTER"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("Twin Center native 3D landmark", app: app)
        app.buttons["Whole city overview"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("Whole Casablanca overview", app: app)
        app.buttons["Reset map camera"].tap()
        XCTAssertTrue(app.buttons["command.start"].isHittable)
    }

    @MainActor
    func testPlanDeployPauseSpeedAndRetry() throws {
        let app = launchOperation(city: "settat")
        let start = app.buttons["command.start"]
        assertDeployed(0, in: app)
        XCTAssertTrue(app.buttons["tool.humvee"].exists)
        XCTAssertTrue(app.buttons["tool.sniper"].exists)
        XCTAssertFalse(app.buttons["tool.garrison"].exists)
        XCTAssertFalse(app.buttons["tool.turret"].exists)
        app.buttons["command.tray"].tap()
        XCTAssertFalse(app.buttons["tool.squad"].exists)
        XCTAssertTrue(start.isHittable)
        app.buttons["command.tray"].tap()
        app.buttons["tool.squad"].tap()
        tapMap(app, x: 0.55, y: 0.52)
        assertDeployed(1, in: app)
        start.tap()
        XCTAssertTrue(app.buttons["command.pause"].waitForExistence(timeout: 5))
        app.buttons["command.pause"].tap()
        XCTAssertTrue(app.buttons["command.resume"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PAUSED"].exists)
        let speed = app.buttons["command.speed"]
        for value in [2, 3, 1] { speed.tap(); XCTAssertEqual(speed.label, "Simulation speed \(value) times") }
        app.buttons["command.resume"].tap()
        XCTAssertTrue(app.buttons["command.pause"].waitForExistence(timeout: 3))
        app.buttons["command.restart"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        assertDeployed(0, in: app)
    }

    @MainActor
    func testHumveeDrawPatrolAndHold() throws {
        let app = launchOperation(city: "settat")
        app.buttons["tool.humvee"].tap()
        tapMap(app, x: 0.55, y: 0.48)
        assertDeployed(1, in: app)
        tapMap(app, x: 0.55, y: 0.48)
        let patrol = app.buttons["unit.patrol"]
        XCTAssertTrue(patrol.waitForExistence(timeout: 4), "Selecting the Humvee should expose its patrol controls.")
        XCTAssertTrue(app.staticTexts["unit.status"].label.contains("HUMVEE"))
        patrol.tap()
        drawMap(app, from: CGVector(dx: 0.55, dy: 0.48), to: CGVector(dx: 0.55, dy: 0.63))
        XCTAssertTrue(patrol.label.contains("PATROLLING"), "A continuous street gesture should commit a patrol route.")
        assertDeployed(1, in: app)
        app.buttons["command.start"].tap()
        settleScene(seconds: 1)
        app.buttons["Whole city overview"].tap()
        settleScene(seconds: 1)
        app.buttons["command.pause"].tap()
        app.buttons["Street level"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("Armed Humvee patrol", app: app)
        app.buttons["unit.hold"].tap()
        XCTAssertEqual(patrol.label, "HOLDING · PATROL", "HOLD should cancel the active patrol route and expose its holding state.")
    }

    @MainActor
    func testDrawBarricadeSelectDurabilityAndRemove() throws {
        let app = launchOperation(city: "settat")
        app.buttons["category.infrastructure"].tap()
        app.buttons["tool.barricade"].tap()
        drawMap(app, from: CGVector(dx: 0.55, dy: 0.47), to: CGVector(dx: 0.55, dy: 0.60))
        assertDeployed(1, in: app)
        tapMap(app, x: 0.55, y: 0.53)
        let status = app.staticTexts["unit.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 4))
        XCTAssertTrue(status.label.contains("BARRIER"))
        XCTAssertTrue(status.label.contains("HP"), "A drawn barricade must expose its finite durability.")
        attachScreenshot("Drawn 3D street barricade and durability", app: app)
        app.buttons["Remove selected unit"].tap()
        assertDeployed(0, in: app)
        app.buttons["tool.evacuation"].tap()
        tapMap(app, x: 0.28, y: 0.59)
        assertDeployed(1, in: app)
        app.buttons["Move map"].tap()
        drawMap(app, from: CGVector(dx: 0.50, dy: 0.46), to: CGVector(dx: 0.65, dy: 0.50))
        app.buttons["Reset map camera"].tap()
        assertDeployed(1, in: app)
    }

    @MainActor
    func testAircraftHeadingWeaponModesAndLiveFlybys() throws {
        let app = launchOperation()
        app.buttons["tool.squad"].tap(); tapMap(app, x: 0.35, y: 0.50)
        app.buttons["tool.humvee"].tap(); tapMap(app, x: 0.65, y: 0.50)
        app.buttons["tool.mortar"].tap(); tapMap(app, x: 0.72, y: 0.58)
        assertDeployed(3, in: app)
        app.buttons["category.air"].tap()
        for kind in ["ac130", "b2", "a10"] { XCTAssertTrue(app.buttons["tool.\(kind)"].isHittable) }
        XCTAssertFalse(app.buttons["tool.airstrike"].exists)
        XCTAssertFalse(app.buttons["tool.helicopter"].exists)
        app.buttons["command.start"].tap()
        app.buttons["command.speed"].tap(); app.buttons["command.speed"].tap()
        waitForInfected(in: app)
        XCTAssertTrue(app.buttons["command.pause"].exists)
        app.buttons["command.pause"].tap()
        app.buttons["map.arrivals"].tap()
        let track = app.buttons["map.herd.0.track"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.tap()
        app.buttons["tool.ac130"].tap()
        let mode = app.buttons["air.weapon"]
        XCTAssertTrue(mode.label.contains("30 mm")); mode.tap(); XCTAssertTrue(mode.label.contains("105 mm"))
        tapMap(app, x: 0.55, y: 0.49)
        assertDeployed(4, in: app)
        app.buttons["tool.b2"].tap()
        let heading = app.buttons["air.heading"]
        let initialHeading = heading.label
        heading.tap(); XCTAssertNotEqual(heading.label, initialHeading)
        tapMap(app, x: 0.53, y: 0.51)
        assertDeployed(5, in: app)
        app.buttons["tool.a10"].tap()
        XCTAssertTrue(heading.isHittable)
        tapMap(app, x: 0.55, y: 0.49)
        assertDeployed(6, in: app)
        app.buttons["command.resume"].tap()
        let firedA10Ammo = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^(0|[1-9][0-9]?|[1-4][0-9]{2}|5[0-3][0-9]) AMMO · [4-8]s$")).firstMatch
        XCTAssertTrue(firedA10Ammo.waitForExistence(timeout: 30), "The A-10 must reach its strafing corridor and expend GAU-8 ammunition.")
        app.buttons["command.pause"].tap()
        XCTAssertTrue(app.buttons["command.resume"].waitForExistence(timeout: 4))
        attachScreenshot("Casablanca AC-130 B-2 A-10 live support", app: app)
        app.buttons["Zoom in"].tap(); app.buttons["Zoom in"].tap()
        attachScreenshot("Casablanca aircraft attack close view", app: app)
    }

    @MainActor
    func testStreetScaleSnipersAndOutsideCityCrowd() throws {
        let app = launchOperation()
        app.buttons["tool.humvee"].tap(); tapMap(app, x: 0.65, y: 0.50)
        assertDeployed(1, in: app)
        tapMap(app, x: 0.65, y: 0.50)
        XCTAssertTrue(app.staticTexts["unit.status"].waitForExistence(timeout: 4))
        app.buttons["Street level"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("V6 Humvee physical street scale", app: app)
        app.buttons["Reset map camera"].tap()
        app.buttons["tool.squad"].tap(); tapMap(app, x: 0.35, y: 0.50)
        assertDeployed(2, in: app)
        tapMap(app, x: 0.35, y: 0.50)
        app.buttons["Street level"].tap()
        app.buttons["Zoom in"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("V6 articulated rifle squad", app: app)
        app.buttons["Reset map camera"].tap()
        app.buttons["tool.sniper"].tap(); tapMap(app, x: 0.72, y: 0.58)
        assertDeployed(3, in: app)
        tapMap(app, x: 0.72, y: 0.58)
        XCTAssertTrue(app.staticTexts["unit.status"].label.contains("SNIPER"))
        app.buttons["Street level"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("V6 sniper team at street level", app: app)
        app.buttons["Move map"].tap()
        app.buttons["Reset map camera"].tap()
        app.buttons["command.start"].tap()
        app.buttons["command.speed"].tap(); app.buttons["command.speed"].tap()
        waitForInfected(in: app, minimum: 100)
        app.buttons["command.pause"].tap()
        app.buttons["map.arrivals"].tap()
        let track = app.buttons["map.herd.0.track"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        XCTAssertTrue(track.label.contains("INFECTED"))
        track.tap()
        app.buttons["Street level"].tap()
        app.buttons["Zoom in"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("V6 exterior herd articulated crowd", app: app)
        app.buttons["command.speed"].tap()
        app.buttons["command.resume"].tap()
        settleScene(seconds: 2)
        app.buttons["command.pause"].tap()
        attachScreenshot("V6 flowing crowd running poses", app: app)
        app.buttons["Whole city overview"].tap()
        settleScene(seconds: 0.7)
        attachScreenshot("V6 outside-city herd locations", app: app)
    }

    @MainActor
    func testSoundSettingsBRRRTAndMute() throws {
        let app = launchOperation(city: "settat")
        app.buttons["command.sound"].tap()
        let preview = app.buttons["sound.brrrt"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        let enabled = app.switches["sound.enabled"]
        XCTAssertTrue(enabled.exists)
        enabled.tap()
        XCTAssertFalse(preview.isEnabled, "Mute should disable the audible BRRRT preview.")
        enabled.tap()
        XCTAssertTrue(preview.isEnabled)
        XCTAssertEqual(app.sliders.count, 2)
        app.sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.8)
        attachScreenshot("Sound mixer and GAU-8 BRRRT", app: app)
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.buttons["command.start"].isHittable)
    }

    @MainActor
    func testTwoCitySelectionAndUpgradePersistence() throws {
        let app = launchOperation(city: "settat")
        app.buttons["command.loadout"].tap()
        let upgrade = app.buttons["upgrade.squad"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        let sniper = app.buttons["upgrade.sniper"]
        XCTAssertTrue(sniper.exists)
        XCTAssertFalse(app.buttons["upgrade.garrison"].exists)
        XCTAssertFalse(app.buttons["upgrade.turret"].exists)
        XCTAssertTrue(upgrade.label.contains("Current level 0"))
        upgrade.tap(); XCTAssertTrue(upgrade.label.contains("Current level 1"))
        sniper.tap(); XCTAssertTrue(sniper.label.contains("Current level 1"))
        attachScreenshot("New task force loadout", app: app)
        app.buttons["sheet.close"].tap()
        for city in ["casablanca", "settat"] {
            selectCity(city, in: app)
            XCTAssertTrue(app.buttons["command.start"].isHittable)
            assertDeployed(0, in: app)
        }
        app.buttons["command.loadout"].tap()
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        XCTAssertTrue(upgrade.label.contains("Current level 1"), "Purchased upgrades must survive every city change.")
        XCTAssertTrue(sniper.label.contains("Current level 1"), "Sniper progression must survive every city change.")
    }

    @MainActor
    func testPaidTacticalReservesDropMobilizeAndShowPausedEffects() throws {
        let app = launchOperation(city:"settat")
        app.buttons["command.start"].tap()
        app.buttons["command.pause"].tap()
        app.buttons["category.support"].tap()
        let call = app.buttons["support.callToArms"]
        let tray = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height < 100 }
        XCTAssertNotNil(tray)
        if !call.isHittable { tray?.swipeLeft() }
        XCTAssertTrue(call.isHittable)
        call.tap()
        // An actual resident on a Settat street near the initial focus; the
        // Kasbah center itself is a solid parcel and cannot recruit through it.
        tapMap(app,x:0.475,y:0.51)
        XCTAssertTrue(call.label.contains("0 use remaining"))
        let initial = deployedCount(in:app)
        XCTAssertGreaterThan(initial,0,"Call to arms should mobilize actual nearby residents.")
        tray?.swipeRight()
        let gas = app.buttons["support.gasBomb"]
        XCTAssertTrue(gas.isHittable); gas.tap(); tapMap(app,x:0.475,y:0.51)
        XCTAssertTrue(gas.label.contains("0 use remaining"))
        app.buttons["Street level"].tap()
        settleScene(seconds:0.5)
        attachScreenshot("V6 paused gas cloud and armed residents",app:app)
        app.buttons["Reset map camera"].tap()
        let para = app.buttons["support.paratroopers"]
        para.tap(); tapMap(app,x:0.55,y:0.52)
        XCTAssertTrue(para.label.contains("0 use remaining"))
        XCTAssertEqual(deployedCount(in:app),initial,"Airborne squads must land before joining the ground roster.")
        app.buttons["command.resume"].tap()
        let landed = NSPredicate { _,_ in self.deployedCount(in:app) == initial+2 }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:landed,object:app)],timeout:10),.completed)
        app.buttons["command.pause"].tap()
        let fire = app.buttons["support.fireBomb"]
        if !fire.isHittable { tray?.swipeLeft() }
        fire.tap(); tapMap(app,x:0.5,y:0.48)
        XCTAssertTrue(fire.label.contains("0 use remaining"))
        app.buttons["command.resume"].tap(); settleScene(seconds:1)
        app.buttons["command.pause"].tap()
        XCTAssertTrue(app.staticTexts["command.collateral"].exists,"Paid fire support must expose building/civilian collateral.")
        attachScreenshot("V6 paid tactical reserves and fire damage",app:app)
        app.buttons["command.restart"].tap()
        app.buttons["category.support"].tap()
        XCTAssertTrue(app.buttons["support.gasBomb"].label.contains("1 use remaining"),"Retry must replenish mission reserves.")
    }

    @MainActor
    private func deployedCount(in app:XCUIApplication) -> Int {
        Int(app.staticTexts["command.units"].label.split(separator:" ").first ?? "") ?? -1
    }

    @MainActor
    func testLandscapeMapAndCommandsRemainUsable() throws {
        let app = launchOperation()
        XCUIDevice.shared.orientation = .landscapeLeft
        let start = app.buttons["command.start"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        assertFullscreenMap(in: app)
        for id in ["command.city", "command.loadout", "command.sound", "tool.squad"] { XCTAssertTrue(app.buttons[id].isHittable) }
        tapMap(app, x: 0.62, y: 0.47)
        assertDeployed(1, in: app)
        settleScene(seconds: 0.7)
        attachScreenshot("Landscape Casablanca 3D command", app: app)
        app.buttons["Whole city overview"].tap()
        attachScreenshot("Landscape whole Casablanca", app: app)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launchOperation(city: String? = "casablanca") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        if let city { app.launchArguments.append("--uitesting-city=\(city)") }
        app.launch()
        XCTAssertTrue(app.buttons["command.start"].waitForExistence(timeout: 30), "Planning controls should appear after the city is loaded.")
        let cityReady = XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:app.buttons["command.city"])],timeout:8)
        if cityReady != .completed {
            attachScreenshot("Planning control reachability failure",app:app)
            let hierarchy = XCTAttachment(string:app.debugDescription)
            hierarchy.name = "Planning control accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(cityReady,.completed,"The planning header must be reachable after launch/rotation settles.")
        for id in ["command.city", "command.help", "command.start", "command.loadout", "command.sound", "tool.squad"] {
            XCTAssertTrue(app.buttons[id].isHittable, "Portrait layout should keep \(id) reachable.")
        }
        assertFullscreenMap(in: app)
        XCTAssertTrue(app.buttons["tool.sniper"].exists)
        XCTAssertFalse(app.buttons["tool.garrison"].exists)
        return app
    }

    @MainActor
    private func waitForInfected(in app: XCUIApplication, minimum: Int = 10) {
        let infected = app.descendants(matching: .any)["command.infected"]
        let predicate = NSPredicate { _, _ in
            let digits = infected.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return (digits.last ?? 0) >= minimum
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: infected)], timeout: 90)
        XCTAssertEqual(result, .completed, "A real exterior column should release at least \(minimum) infected; HUD was \(infected.label).")
    }

    @MainActor
    private func selectCity(_ city: String, in app: XCUIApplication) {
        app.buttons["command.city"].tap()
        let cityButton = app.buttons["operations.city.\(city)"]
        XCTAssertTrue(cityButton.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","operations.city.")).count,2)
        for removed in ["newYork","paris","losAngeles","venice"] { XCTAssertFalse(app.buttons["operations.city.\(removed)"].exists) }
        // The underlying command tray is also a ScrollView. Scroll the tall
        // sheet content, rather than sending a short swipe to the hidden tray.
        let content = app.scrollViews.allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 200 }
        XCTAssertNotNil(content, "Operations should expose a scrollable sheet.")
        for _ in 0..<6 where !cityButton.isHittable {
            if cityButton.frame.midY > 0 && cityButton.frame.midY < (content?.frame.minY ?? 0) { content?.swipeDown() }
            else { content?.swipeUp() }
        }
        if !cityButton.isHittable {
            attachScreenshot("City picker scrolling failure", app: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "City picker scroll hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertTrue(cityButton.isHittable)
        cityButton.tap()
        XCTAssertTrue(app.buttons["command.start"].waitForExistence(timeout: 15))
        let title = ["casablanca":"CASABLANCA", "settat":"SETTAT"][city]!
        XCTAssertTrue(app.buttons["command.city"].label.contains(title))
    }

    @MainActor
    private func assertFullscreenMap(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let map = app.otherElements["command.map"]
        XCTAssertTrue(map.exists, file:file,line:line)
        XCTAssertGreaterThanOrEqual(map.frame.height,app.frame.height*0.95,file:file,line:line)
        XCTAssertGreaterThanOrEqual(map.frame.width,app.frame.width*0.95,file:file,line:line)
    }

    @MainActor
    private func tapMap(_ app: XCUIApplication, x: Double, y: Double) {
        app.otherElements["command.map"].coordinate(withNormalizedOffset:CGVector(dx:x,dy:y)).tap()
    }

    @MainActor
    private func drawMap(_ app: XCUIApplication, from a: CGVector, to b: CGVector) {
        let map = app.otherElements["command.map"]
        map.coordinate(withNormalizedOffset:a).press(forDuration:0.1,thenDragTo:map.coordinate(withNormalizedOffset:b))
    }

    @MainActor
    private func assertDeployed(_ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deployed = app.staticTexts["command.units"]
        let expected = NSPredicate(format:"label == %@","\(count) DEPLOYED")
        let result = XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:expected,object:deployed)],timeout:5)
        XCTAssertEqual(result,.completed,"Expected \(count) deployed defenses; actual HUD: \(deployed.label)",file:file,line:line)
    }

    @MainActor
    private func settleScene(seconds: TimeInterval) {
        let done = XCTestExpectation(description:"Allow real simulation and rendering to advance")
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds) { done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:seconds+1),.completed)
    }

    @MainActor
    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
