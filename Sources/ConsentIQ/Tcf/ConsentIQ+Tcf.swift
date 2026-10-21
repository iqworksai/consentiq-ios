import Foundation

struct TcfPendingOpen {
    weak var presenter: AnyObject?
    let fallback: (() -> Void)?
}

enum TcfRunResult {
    case shown
    case finished
    case failed
    case stale
}

extension ConsentIQ {
    func prepareTcf(_ propertyConfig: PropertyConfig) {
        guard let tcf = propertyConfig.tcf, tcf.isInAppEnabled, let cmpId = tcf.cmpId else {
            turnTcfOff()
            return
        }
        if !tcfKeys.claimCmp(id: cmpId, version: tcf.cmpVersion) {
            logger.warning("Another CMP's IABTCF keys are on this device; ConsentIQ replaces them once the visitor decides")
        }
        if tcf.gdprApplies == false {
            tcfKeys.writeGdprApplies(0)
            isTcfActive = false
            return
        }
        isTcfActive = true
    }

    func startTcf(reopen: Bool, presenter: AnyObject? = nil, fallback: (() -> Void)? = nil) {
        guard tcfTask == nil else {
            if reopen, tcfSession?.shown != true {
                tcfPendingOpen = TcfPendingOpen(presenter: presenter, fallback: fallback)
            }
            return
        }
        tcfRun &+= 1
        let run = tcfRun
        let anchor = TcfPendingOpen(presenter: presenter, fallback: nil)
        tcfTask = Task { [weak self] in
            guard let self else { return }
            let result = await runTcf(run, reopen: reopen, presenter: anchor, fallback: fallback)
            guard tcfRun == run else { return }
            tcfTask = nil
            runPendingOpen(after: result)
        }
    }

    func endTcfSession() {
        tcfRun &+= 1
        tcfPendingOpen = nil
        tcfSession?.cancel()
        tcfSession = nil
        tcfTask = nil
    }

    // A native-sheet choice made after the TCF screens failed must not leave an older TC string for vendors to read.
    func discardTcfDecisionAfterNativeChoice() {
        guard tcfFellBack else { return }
        tcfKeys.clearDecision()
        storage.clearTcf()
    }

    private func turnTcfOff() {
        tcfKeys.clearAll()
        storage.clearTcf()
        isTcfActive = false
        tcfFellBack = false
    }

    private func runTcf(_ run: Int, reopen: Bool, presenter: TcfPendingOpen, fallback: (() -> Void)?) async -> TcfRunResult {
        guard run == tcfRun, let configuration else { return .stale }
        let pageURL = TcfSession.pageURL(apiURL: configuration.apiURL, propertyKey: configuration.propertyKey)
        guard let page = tcfPageFactory(pageURL, presenter.presenter) else {
            fallBackFromTcf(TcfError(code: TcfError.unavailable), reopen: reopen, fallback: fallback)
            return .failed
        }
        let options = TcfStartOptions(
            subjectId: subjectId ?? "",
            stored: storage.loadTcfStored(),
            consent: consent,
            reopen: reopen,
            token: UUID().uuidString
        )
        let session = TcfSession(
            page: page,
            options: options,
            readyTimeoutNanoseconds: tcfReadyTimeoutNanoseconds,
            answerTimeoutNanoseconds: tcfAnswerTimeoutNanoseconds
        ) { [weak self] in
            self?.configuration?.onOpen?()
        }
        tcfSession = session
        let outcome = await session.run()
        guard run == tcfRun else {
            page.close()
            return .stale
        }
        tcfSession = nil
        page.close()
        let result: TcfRunResult = session.shown ? .shown : .finished

        switch outcome {
        case .current:
            tcfFellBack = false
            tcfKeys.writeGdprApplies(1)
        case .decision(let decision):
            tcfFellBack = false
            applyTcfDecision(decision)
            reportTcfDecision(scope: decision.scope ?? inferredTcfScope(), configuration: configuration)
            configuration.onConsentChange?(consent, marketingConsent)
        case .notApplicable:
            tcfKeys.writeGdprApplies(0)
            isTcfActive = false
            runNativeFallback(reopen: reopen, fallback: fallback)
        case .tcfOff:
            turnTcfOff()
            runNativeFallback(reopen: reopen, fallback: fallback)
        case .closed:
            tcfFellBack = false
            configuration.onClose?()
        case .failed(let error):
            fallBackFromTcf(error, reopen: reopen, fallback: fallback)
            return .failed
        case .cancelled:
            return .stale
        }
        return result
    }

    private func runPendingOpen(after result: TcfRunResult) {
        guard let pending = tcfPendingOpen else { return }
        tcfPendingOpen = nil
        switch result {
        case .shown, .stale:
            return
        case .failed:
            if !isSheetVisible {
                runNativeFallback(reopen: true, fallback: pending.fallback)
            }
        case .finished:
            if isTcfActive {
                startTcf(reopen: true, presenter: pending.presenter, fallback: pending.fallback)
            } else {
                runNativeFallback(reopen: true, fallback: pending.fallback)
            }
        }
    }

    // The page has already recorded this consent with ConsentIQ, so it is applied locally and never re-submitted.
    private func applyTcfDecision(_ decision: TcfDecision) {
        if let tcf = config?.tcf, let cmpId = tcf.cmpId {
            tcfKeys.takeOverCmp(id: cmpId, version: tcf.cmpVersion)
        }
        tcfKeys.write(keys: decision.keys)
        if let stored = decision.stored {
            storage.saveTcfStored(stored)
        }
        if let decided = decision.consent {
            consent = decided.forcingNecessary()
            storage.saveConsent(consent)
        }
        logger.debug("TCF decision applied")
    }

    private func reportTcfDecision(scope: TcfDecision.Scope, configuration: ConsentIQConfig) {
        switch scope {
        case .acceptAll: configuration.onAccept?(ConsentOutcome(scope: .all, consent: consent))
        case .rejectAll: configuration.onReject?(ConsentOutcome(consent: consent))
        case .custom: configuration.onSave?(ConsentOutcome(consent: consent))
        }
    }

    private func inferredTcfScope() -> TcfDecision.Scope {
        let optional = (config?.categories ?? [])
            .filter { $0.enabled && !$0.isRequired && $0.code != ConsentCategory.necessary }
            .map(\.code)
        guard !optional.isEmpty else { return .custom }
        let granted = optional.filter { consent[$0] == true }.count
        if granted == optional.count { return .acceptAll }
        if granted == 0 { return .rejectAll }
        return .custom
    }

    private func fallBackFromTcf(_ error: TcfError, reopen: Bool, fallback: (() -> Void)?) {
        logger.error("TCF screen unavailable, using the consent sheet: \(error.code)")
        tcfFellBack = true
        configuration?.onError?(error)
        runNativeFallback(reopen: reopen, fallback: fallback)
    }

    private func runNativeFallback(reopen: Bool, fallback: (() -> Void)?) {
        if let fallback {
            fallback()
        } else if reopen {
            openNativeSheet()
        } else if configuration?.autoShow == true, !hasExistingConsent {
            openNativeSheet()
        }
    }
}
