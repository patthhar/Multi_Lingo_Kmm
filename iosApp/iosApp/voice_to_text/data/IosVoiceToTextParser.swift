//
//  IosVoiceToTextParser.swift
//  iosApp
//
//  Created by Parth Takkar on 24/08/23.
//  Copyright © 2023 orgName. All rights reserved.
//

import Combine
import Foundation
import Speech
import shared

class IosVoiceToTextParser: VoiceToTextParser, ObservableObject {
    private let _state = IosMutableStateFlow(
        initialValue: VoiceToTextParserState(
            transcribedResult: "", error: nil, powerRatio: 0.0, isSpeaking: false
        ))
    var state: CStateFlow<VoiceToTextParserState> { _state }

    private var micObserver = MicPowerObserver()
    var micPowerRatio: Published<Double>.Publisher {
        micObserver.$micPowerRatio
    }
    private var micPowerCancellable: AnyCancellable?
    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioBufferRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioSession: AVAudioSession?

    func cancel() {  // not needed on iOS
    }

    func reset() {
        self.stopListening()
        _state.value = VoiceToTextParserState(
            transcribedResult: "", error: nil, powerRatio: 0.0, isSpeaking: false
        )
    }

    func startListening(languageCode: String) {
        updateState(error: nil)
        let chosenLocale = Locale.init(identifier: languageCode)
        let supportedLocale =
            SFSpeechRecognizer.supportedLocales().contains(chosenLocale)
            ? chosenLocale : Locale.init(identifier: "en-US")

        self.recognizer = SFSpeechRecognizer(locale: supportedLocale)
        guard recognizer?.isAvailable == true else {
            updateState(error: "Speech recognition unavailable")
            return
        }

        audioSession = AVAudioSession.sharedInstance()
        self.requestPermissions { [weak self] in
            self?.audioBufferRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let audioBufferRequest = self?.audioBufferRequest else {
                return
            }

            self?.recognitionTask = self?.recognizer?.recognitionTask(with: audioBufferRequest) {
                [weak self] (result, error) in
                guard let result = result else {
                    self?.updateState(error: error?.localizedDescription)
                    return
                }

                if result.isFinal {
                    self?.updateState(voiceResult: result.bestTranscription.formattedString)
                }
            }

            self?.audioEngine = AVAudioEngine()
            self?.inputNode = self?.audioEngine?.inputNode

            let recordingFormat = self?.inputNode?.outputFormat(forBus: 0)
            self?.inputNode?.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
                buffer, _ in
                self?.audioBufferRequest?.append(buffer)
            }

            self?.audioEngine?.prepare()

            do {
                try self?.audioSession?.setCategory(
                    .playAndRecord, mode: .spokenAudio, options: .duckOthers)
                try self?.audioSession?.setActive(true, options: .notifyOthersOnDeactivation)

                self?.micObserver.startObserving()

                try self?.audioEngine?.start()

                self?.updateState(isSpeaking: true)

                self?.micPowerCancellable = self?.micPowerRatio
                    .sink { [weak self] ratio in
                        self?.updateState(powerRatio: ratio)
                    }
            } catch {
                self?.updateState(error: error.localizedDescription, isSpeaking: false)
            }
        }
    }

    func stopListening() {
        self.updateState(isSpeaking: false)
        micPowerCancellable = nil
        micObserver.release()

        audioBufferRequest?.endAudio()
        audioBufferRequest = nil

        audioEngine?.stop()

        inputNode?.removeTap(onBus: 0)
        try? audioSession?.setActive(false)
        audioSession = nil
    }

    private func updateState(
        voiceResult: String? = nil, error: String? = nil, powerRatio: CGFloat? = nil,
        isSpeaking: Bool? = nil
    ) {
        let currentState = _state.value
        _state.value = VoiceToTextParserState(
            transcribedResult: voiceResult ?? currentState?.transcribedResult ?? "",
            error: error ?? currentState?.error,
            powerRatio: Float(powerRatio ?? CGFloat(currentState?.powerRatio ?? 0.0)),
            isSpeaking: isSpeaking ?? currentState?.isSpeaking ?? false
        )
    }

    private func requestPermissions(onGranted: @escaping () -> Void) {
        audioSession?.requestRecordPermission { [weak self] wasGranted in
            if !wasGranted {
                self?.updateState(error: "Permission not granted")
                self?.stopListening()
                return
            }
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status != .authorized {
                        self?.updateState(error: "Permission denied")
                        self?.stopListening()
                        return
                    }
                    onGranted()
                }
            }
        }
    }
}
