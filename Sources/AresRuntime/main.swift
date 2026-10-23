import AppKit
import Darwin
import Foundation
import FileOrganizerCore
import EcosystemRuntimeSupport
import EcosystemLocalIPC
import EcosystemLocalization

/// Явный local-ad-hoc runtime. Не регистрирует себя, не читает прежнюю БД и
/// работает только с профилем, переданным локальным launcher через --config.
@main struct AresRuntime {
    static func main() {
        if LocalizationProbe.runIfRequested() { exit(0) }
        do {
            if try LocalRuntimeCLI.clientIfRequested(domain: "ares") { return }
            umask(0o077)
            let file = try LocalRuntimeCLI.configurationFile()
            let config = try LocalRuntimeConfiguration.load(file, domain: "ares")
            let state = file.deletingLastPathComponent().appendingPathComponent("ares-state", isDirectory: true)
            let queue = try DurableTaskQueue(directory: state.appendingPathComponent("queue"), agentID: .ares, fault: try LocalRuntimeCLI.faultForSyntheticProfile(file))
            let container = AppContainer(databaseURL: state.appendingPathComponent("domain.sqlite"), allowLocalClient: false, runtimeOwnedStore: true)
            try container.preparePersistentStore()
            let policy = try LocalAccessPolicy(directory: state, domain: "ares")
            let work = try AresQueuedWork(queue: queue, repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator, policy: policy)
            let automation = try LocalAutomationService(directory: state, domain: "ares")
            let history = try LocalMCPHistory(directory: state, domain: "ares", queue: queue, policy: policy,
                inbox: automation.inbox, authorizeTask: { id, client in
                    try await work.authorizedTask(id, role: .mcp, clientID: client, includeResult: false)
                }, validRoots: {
                    var result = Set<UUID>()
                    for root in try await container.fileRepository.fetchRoots() where try await container.fileRepository.bookmarkData(forRootID: root.id)?.isEmpty == false { result.insert(root.id) }
                    return result
                })
            let service = AresRuntimeService(container: container, work: work, automation: automation, login: LocalLoginRegistration(profile: file.deletingLastPathComponent(), domain: "ares"), history: history)
            let server = try LocalRPCServer(configuration: config, identifiedHandler: { role, client, request in try await service.handle(role: role, clientID: client, request: request) })
            let termination = LocalRuntimeTermination.install { await service.stopObservation(); await work.shutdown() }
            if Bundle.main.bundleURL.pathExtension == "app" { NSApplication.shared.setActivationPolicy(.accessory) }
            let workspace = LocalWakeObserver { Task { await service.wake() } }
            withExtendedLifetime((workspace, termination, queue, work, service, server)) {
                server.resume()
                Task {
                    await container.ruleCoordinator.configureAutomation(scheduler: automation.schedules) { receipt in
                        try await automation.record(id: LocalStableEventID.make("notify:" + receipt), kind: "rule.notification", capability: "rule.history", capturedAt: Date(), significant: true)
                    }
                    try? await work.resume()
                    await service.tick(appLaunch: true)
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        await service.tick()
                    }
                }
                RunLoop.main.run()
            }
        } catch QueueFailure.ownerBusy { fputs("LOCAL_RUNTIME_OWNER_BUSY\n", stderr); exit(73) }
        catch { fputs("LOCAL_RUNTIME_START_FAILED\n", stderr); exit(64) }
    }
}
