import Foundation

@main struct CrowdMotionTests {
    static func main() {
        var checks = 0
        func expect(_ valid: Bool, _ message: String) {
            precondition(valid,message); checks += 1
        }
        var previous = CrowdMotion.gait(at:0)
        for i in 0...800 {
            let v = Double(i)/100, next = CrowdMotion.gait(at:v)
            expect(abs(next.idle+next.walk+next.run-1)<1e-9,"Locomotion weights conserve one complete body")
            expect(abs(next.walk-previous.walk)<0.03 && abs(next.run-previous.run)<0.03,"No idle/walk/run threshold can jump a pose")
            previous = next
        }
        var speed = 0.0
        for _ in 0..<40 {
            let next = CrowdMotion.speed(from:speed,toward:6,dt:0.05,acceleration:5,braking:8)
            expect(next-speed <= 0.2500001 && next >= speed,"Crowd starts obey physical acceleration")
            speed = next
        }
        for _ in 0..<20 {
            let next = CrowdMotion.speed(from:speed,toward:0,dt:0.05,acceleration:5,braking:8)
            expect(speed-next <= 0.4000001 && next >= 0,"Braking never overshoots into reverse movement")
            speed = next
        }
        expect(speed == 0,"A stopped queue does not retain a forced running minimum")
        let angle = CrowdMotion.heading(from:.pi-0.01,toward:-Double.pi+0.01,dt:0.05,rate:5.5)
        expect(abs(angle-(.pi-0.01))<0.021,"Turns use the short arc across the angle seam")
        let candidates = (0..<700).map { (id:$0,position:CGPoint(x:Double($0%35),y:Double($0/35))) }
        let chosen = CrowdDetailSelection.choose(candidates,previous:[],focus:CGPoint(x:17,y:10),budget:160)
        expect(chosen.count==160,"A very dense herd keeps exactly the body budget, not zero bodies")
        let retained = CrowdDetailSelection.choose(candidates,previous:chosen,focus:CGPoint(x:17.1,y:10),budget:160)
        expect(retained.intersection(chosen).count>150,"Small camera/crowd movement does not flicker the entire body selection")
        expect(CrowdDetailSelection.choose(candidates,previous:chosen,focus:CGPoint(x:0,y:0),budget:0).isEmpty,"Overhead mode can request all dots")
        expect(CrowdMotion.cycleLength(at:5)>CrowdMotion.cycleLength(at:1),"Running lengthens the stride instead of only speeding the same walk")
        print("PASS: \(checks) locomotion transition, acceleration and dense-detail checks")
    }
}
