import SceneKit
import Metal
import QuartzCore
import Foundation

/// Counts actual renderer callbacks rather than reporting a configured FPS.
/// A simulator callback measures submitted frames, not hardware presentation
/// or phone temperature. Work counters separately expose main-thread spikes.
final class TacticalFrameMetrics: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let enabled = ProcessInfo.processInfo.arguments.contains("--uitesting-profile")
    private let diagnostics = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--uitesting-no-") }.joined(separator:",")
    private let stagingBuffers = CrowdStagingBuffers()
    private var renderTime: TimeInterval = 0
    private var previousWallTime: TimeInterval = 0
    private var windowStart: TimeInterval = 0
    private var warmUntil: TimeInterval = 0
    private var intervals: [Double] = []
    private var previousUpdateWallTime: TimeInterval = 0
    private var previousUpdateSceneTime: TimeInterval = 0
    private var updateIntervals: [Double] = []
    private var sceneClockIntervals: [Double] = []
    private var work: [String:[Double]] = [:]
    private var workload: [String:Any] = [:]
    private struct GeometryAnimation {
        let geometry: SCNGeometry
        let start: TimeInterval
        let duration: TimeInterval
    }
    private var animations: [String:GeometryAnimation] = [:]
    private struct BufferUpload {
        let vertices: MTLBuffer
        let indices: [MTLBuffer]
        let vertexData: Data
        let indexData: [Data]
    }
    private var uploads: [BufferUpload] = []
    private struct CrowdUpdate {
        let key: String
        let node: SCNNode
        let prepared: PreparedCrowdGeometry
        let materials: [SCNMaterial]
        let animating: Bool
    }
    private var pendingCrowds: [String:CrowdUpdate] = [:]
    // Only the render callback touches these pools.
    private var crowdBuffers: [String:CrowdMetalBuffers] = [:]
    private var resetBuffers = false
    private var retiredBufferKeys = Set<String>()
    private var frozenGeometries: [SCNGeometry] = []

    func enqueueCrowd(key:String,node:SCNNode,prepared:PreparedCrowdGeometry,materials:[SCNMaterial],animating:Bool) {
        lock.lock(); defer { lock.unlock() }
        pendingCrowds[key] = CrowdUpdate(key:key,node:node,prepared:prepared,materials:materials,animating:animating)
    }

    func enqueueUpload(vertices:MTLBuffer,indices:[MTLBuffer],vertexData:Data,indexData:[Data]) {
        lock.lock(); defer { lock.unlock() }
        uploads.append(BufferUpload(vertices:vertices,indices:indices,vertexData:vertexData,indexData:indexData))
    }

    // SceneKit requires changes to its Metal sources inside renderer callbacks.
    // A blit on the renderer's command queue orders writes after prior GPU draws
    // and before this draw; the main thread never waits for GPU completion.
    func renderer(_ renderer:any SCNSceneRenderer,willRenderScene scene:SCNScene,atTime time:TimeInterval) {
        lock.lock(); let pending = uploads; uploads.removeAll(keepingCapacity:true); lock.unlock()
        guard !pending.isEmpty else { return }
        let began = CACurrentMediaTime()
        defer { recordWork(label:"crowdGPUUpload",milliseconds:(CACurrentMediaTime()-began)*1_000) }
        guard let queue = renderer.commandQueue, let command = queue.makeCommandBuffer() else {
            retryUploads(pending); return
        }
        struct Copy {
            let source: MTLBuffer
            let destination: MTLBuffer
            let count: Int
        }
        let pool = stagingBuffers
        var acquired: [MTLBuffer] = []
        var copies: [Copy] = []
        var clear: [MTLBuffer] = []
        func stage(_ data:Data,to destination:MTLBuffer) -> Bool {
            guard !data.isEmpty else { return true }
            guard data.count <= destination.length,
                  let buffer = pool.acquire(device:queue.device,length:data.count) else { return false }
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.contents().copyMemory(from:base,byteCount:bytes.count) }
            }
            acquired.append(buffer)
            copies.append(Copy(source:buffer,destination:destination,count:data.count))
            return true
        }
        for upload in pending {
            guard stage(upload.vertexData,to:upload.vertices) else {
                pool.recycle(acquired); retryUploads(pending); return
            }
            for (destination,data) in zip(upload.indices,upload.indexData) {
                guard stage(data,to:destination) else {
                    pool.recycle(acquired); retryUploads(pending); return
                }
                clear.append(destination)
            }
        }
        guard let blit = command.makeBlitCommandEncoder() else {
            pool.recycle(acquired); retryUploads(pending); return
        }
        // Clear stale indices as well as limiting primitiveRange. Degenerate
        // padding prevents old actors on backends that cache draw ranges.
        for destination in clear { blit.fill(buffer:destination,range:0..<destination.length,value:0) }
        for copy in copies { blit.copy(from:copy.source,sourceOffset:0,to:copy.destination,destinationOffset:0,size:copy.count) }
        blit.endEncoding()
        // A staging buffer becomes CPU-writable only after its last GPU read.
        // No display-thread waits or assumptions about frames in flight.
        let completedBuffers = acquired
        command.addCompletedHandler { _ in pool.recycle(completedBuffers) }
        command.commit()
    }

    private func retryUploads(_ pending:[BufferUpload]) {
        lock.lock(); defer { lock.unlock() }
        // Keep the newest snapshot for each destination if allocation fails.
        // This bounds retries to the existing crowd-buffer slots.
        var seen = Set<ObjectIdentifier>()
        uploads = Array((pending+uploads).reversed().filter { seen.insert(ObjectIdentifier($0.vertices)).inserted }.reversed())
    }

    var currentRenderTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }; return renderTime
    }
    func setWorkload(city: String, view: String, live: Int, staged: Int,
                     phase: String, renderScale: Double, targetFPS: Int,visibleBodies:Int=0,visibleDots:Int=0,speed:Double=1,elapsed:Double=0) {
        lock.lock(); defer { lock.unlock() }
        workload = ["city":city,"view":view,"live":live,"staged":staged,"phase":phase,
                    "renderScale":renderScale,"targetFPS":targetFPS,"visibleBodies":visibleBodies,"visibleDots":visibleDots,"speed":speed,"elapsed":rounded(elapsed)]
        workload["diagnostics"] = diagnostics
    }
    func recordWork(label: String, milliseconds: Double) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        work[label,default:[]].append(milliseconds)
    }
    /// One uniform update per animated batch is independent of crowd size.
    /// Arithmetic uses the delegate's Double clock, avoiding loss of subframe
    /// precision in the shader's Float time on devices with long uptime.
    func registerAnimation(key: String, geometry: SCNGeometry, startTime: TimeInterval,
                           duration: TimeInterval, animating: Bool) {
        // Never hold our clock lock while entering SceneKit. The renderer and
        // main scene transaction acquire SceneKit's own locks in different order.
        geometry.setValue(Float(0),forKey:"crowdEnabled")
        geometry.setValue(Float(animating ? 0 : 1),forKey:"crowdFrozen")
        lock.lock(); defer { lock.unlock() }
        if animating {
            animations[key] = GeometryAnimation(geometry:geometry,start:startTime,duration:max(0.001,duration))
        } else { animations.removeValue(forKey:key) }
    }
    func unregisterAnimation(key: String) {
        lock.lock(); defer { lock.unlock() }
        animations.removeValue(forKey:key); pendingCrowds.removeValue(forKey:key); retiredBufferKeys.insert(key)
    }
    func clearAnimations() {
        lock.lock()
        frozenGeometries.append(contentsOf:animations.values.map(\.geometry))
        animations.removeAll(keepingCapacity:true); pendingCrowds.removeAll(keepingCapacity:true)
        lock.unlock()
    }
    func reset() {
        lock.lock()
        previousWallTime = 0; windowStart = 0; warmUntil = 0
        intervals.removeAll(keepingCapacity:true); work.removeAll(keepingCapacity:true)
        previousUpdateWallTime = 0; previousUpdateSceneTime = 0
        updateIntervals.removeAll(keepingCapacity:true); sceneClockIntervals.removeAll(keepingCapacity:true)
        frozenGeometries.append(contentsOf:animations.values.map(\.geometry))
        animations.removeAll(keepingCapacity:true); uploads.removeAll(keepingCapacity:true)
        pendingCrowds.removeAll(keepingCapacity:true); resetBuffers = true
        lock.unlock()
    }
    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let updateWallTime = enabled ? CACurrentMediaTime() : 0
        lock.lock()
        if enabled {
            let interval = updateWallTime-previousUpdateWallTime
            let sceneInterval = time-previousUpdateSceneTime
            // Use the same warm-up and reporting windows as didRenderScene.
            // These starts distinguish scheduling from end-of-encoding jitter;
            // neither callback measures presentation on the display.
            if previousWallTime != 0, previousUpdateWallTime != 0,
               updateWallTime >= warmUntil, interval >= 0, interval <= 0.5 {
                updateIntervals.append(interval*1_000)
                if sceneInterval >= 0, sceneInterval <= 0.5 { sceneClockIntervals.append(sceneInterval*1_000) }
            }
            previousUpdateWallTime = updateWallTime; previousUpdateSceneTime = time
        }
        renderTime = time
        let pending = pendingCrowds; pendingCrowds.removeAll(keepingCapacity:true)
        let freeze = frozenGeometries; frozenGeometries.removeAll(keepingCapacity:true)
        let reset = resetBuffers; resetBuffers = false
        let retired = retiredBufferKeys; retiredBufferKeys.removeAll(keepingCapacity:true)
        lock.unlock()
        for key in retired { crowdBuffers.removeValue(forKey:key) }
        if reset { crowdBuffers.removeAll() }
        for geometry in freeze { geometry.setValue(Float(1),forKey:"crowdFrozen") }
        if !pending.isEmpty {
            let began = CACurrentMediaTime()
            SCNTransaction.begin(); SCNTransaction.disableActions = true
            for update in pending.values where update.node.parent != nil && !update.node.isHidden {
                if crowdBuffers[update.key] == nil, let device = renderer.device { crowdBuffers[update.key] = CrowdMetalBuffers(device:device) }
                let geometry = crowdBuffers[update.key]?.update(update.prepared,materials:update.materials,uploads:self)
                    ?? update.prepared.geometry(materials:update.materials,snapshotTime:time,snapshotDuration:0.05,animating:update.animating)
                update.node.geometry = geometry
                registerAnimation(key:update.key,geometry:geometry,startTime:time,duration:0.05,animating:update.animating)
            }
            SCNTransaction.commit()
            recordWork(label:"crowdUpload",milliseconds:(CACurrentMediaTime()-began)*1_000)
            for update in pending.values where update.node.parent == nil { crowdBuffers.removeValue(forKey:update.key) }
        }
        lock.lock(); let current = animations; lock.unlock()
        var finished: [(String, SCNGeometry)] = []
        for (key, animation) in current {
            let fraction = max(0,min(1,(time-animation.start)/animation.duration))
            animation.geometry.setValue(Float(fraction),forKey:"crowdFrozen")
            if fraction >= 1 { finished.append((key,animation.geometry)) }
        }
        lock.lock()
        for (key, geometry) in finished where animations[key]?.geometry === geometry {
            animations.removeValue(forKey:key)
        }
        lock.unlock()
    }
    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let now = CACurrentMediaTime()
        lock.lock()
        renderTime = time
        guard enabled else { lock.unlock(); return }
        if previousWallTime == 0 {
            previousWallTime = now; warmUntil = now+2; windowStart = warmUntil
            lock.unlock(); return
        }
        let interval = now-previousWallTime
        previousWallTime = now
        guard now >= warmUntil else { lock.unlock(); return }
        if interval > 0.5 {
            // Resuming from background starts a new window. It is not a draw hitch.
            warmUntil = now+2; windowStart = warmUntil
            intervals.removeAll(keepingCapacity:true); work.removeAll(keepingCapacity:true)
            previousUpdateWallTime = 0; previousUpdateSceneTime = 0
            updateIntervals.removeAll(keepingCapacity:true); sceneClockIntervals.removeAll(keepingCapacity:true)
            lock.unlock(); return
        }
        intervals.append(interval*1_000)
        guard now-windowStart >= 6 else { lock.unlock(); return }
        var result = workload
        result["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        result["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        let span = now-windowStart
        let sorted = intervals.sorted()
        result["seconds"] = rounded(span)
        result["sceneClock"] = rounded(time)
        result["frames"] = intervals.count
        result["renderCallbacksFPS"] = rounded(Double(intervals.count)/span)
        result["p50ms"] = rounded(percentile(sorted,0.5))
        result["p95ms"] = rounded(percentile(sorted,0.95))
        result["maxms"] = rounded(sorted.last ?? 0)
        result["minms"] = rounded(sorted.first ?? 0)
        result["p05ms"] = rounded(percentile(sorted,0.05))
        result["intervalsUnder5ms"] = intervals.filter { $0 < 5 }.count
        let sortedUpdates = updateIntervals.sorted()
        result["updateFrames"] = updateIntervals.count
        result["updateCallbacksFPS"] = rounded(Double(updateIntervals.count)/span)
        result["updateP50ms"] = rounded(percentile(sortedUpdates,0.5))
        result["updateP95ms"] = rounded(percentile(sortedUpdates,0.95))
        result["sceneClockDeltaP95ms"] = rounded(percentile(sceneClockIntervals.sorted(),0.95))
        result["hitchesOver25ms"] = intervals.filter { $0 > 25 }.count
        result["hitchesOver50ms"] = intervals.filter { $0 > 50 }.count
        result["work"] = work.mapValues { values -> [String:Any] in
            let sorted = values.sorted()
            return ["count":values.count,"p50ms":rounded(percentile(sorted,0.5)),
                    "p95ms":rounded(percentile(sorted,0.95)),"maxms":rounded(sorted.last ?? 0)]
        }
        windowStart = now
        intervals.removeAll(keepingCapacity:true); work.removeAll(keepingCapacity:true)
        updateIntervals.removeAll(keepingCapacity:true); sceneClockIntervals.removeAll(keepingCapacity:true)
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),
           let text = String(data:data,encoding:.utf8) { print("ZOMBOYS_FRAMES \(text)") }
    }
    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count-1,Int((Double(sorted.count-1)*fraction).rounded(.up)))]
    }
    private func rounded(_ value: Double) -> Double { (value*100).rounded()/100 }
}

/// Shared CPU staging memory is returned by GPU completion, never by frame count.
/// Only idle buffers are cached; a device change discards the old device's pool.
private final class CrowdStagingBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var deviceID: ObjectIdentifier?
    private var buckets: [Int:[MTLBuffer]] = [:]
    private var cachedBytes = 0
    private let maximumCachedBytes = 16*1_024*1_024
    private let maximumBuffersPerBucket = 4

    func acquire(device:MTLDevice,length:Int) -> MTLBuffer? {
        guard length > 0 else { return nil }
        var capacity = 256
        while capacity < length {
            guard capacity <= Int.max/2 else { return nil }
            capacity *= 2
        }
        let identity = ObjectIdentifier(device)
        lock.lock()
        if deviceID != identity {
            buckets.removeAll(); cachedBytes = 0; deviceID = identity
        }
        let buffer = buckets[capacity]?.popLast()
        if let buffer { cachedBytes -= buffer.length }
        lock.unlock()
        return buffer ?? device.makeBuffer(length:capacity,options:.storageModeShared)
    }

    func recycle(_ buffers:[MTLBuffer]) {
        lock.lock(); defer { lock.unlock() }
        for buffer in buffers where ObjectIdentifier(buffer.device) == deviceID {
            let size = buffer.length
            guard size <= maximumCachedBytes-cachedBytes,
                  (buckets[size]?.count ?? 0) < maximumBuffersPerBucket else { continue }
            buckets[size,default:[]].append(buffer); cachedBytes += size
        }
    }
}
