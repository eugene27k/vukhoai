import Foundation

struct OpenAIProtocolService {
    static let shared = OpenAIProtocolService()

    func testConnection(apiKey: String, model: String) async throws {
        let _: String = try await complete(
            apiKey: apiKey,
            model: model,
            systemPrompt: "You are a connectivity test responder.",
            userPrompt: "Reply exactly with: OK",
            maxTokens: 8
        )
    }

    func generateMeetingProtocol(apiKey: String, model: String, transcript: String) async throws -> String {
        let systemPrompt = """
        You convert transcripts into structured meeting minutes in Ukrainian.
        Output ONLY markdown with no greetings, no preamble, and no trailing commentary.
        Be factual and rely only on the transcript.
        """

        let userPrompt = """
        Створи протокол зустрічі у markdown-форматі.

        Вимоги:
        1) Тільки українська мова.
        2) Жодних вступних фраз, типу "Ось протокол".
        3) Строга структура секцій:
           ## Учасники
           ## Про що говорили
           ## Що вирішили
           ## Домовленості і наступні кроки
        4) Учасників називай так, як є в транскрипті (наприклад SPEAKER_01, SPEAKER_02).
        5) Якщо даних у секції бракує, пиши "Не визначено".
        6) Стисла, суха, протокольна форма без зайвого тексту.

        Транскрипт:
        \(transcript)
        """

        return try await complete(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 1400
        )
    }

    private func complete(apiKey: String, model: String, systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ServiceError.missingModel
        }

        let requestBody = ChatCompletionRequest(
            model: trimmedModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.2,
            max_tokens: max(1, maxTokens)
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
               let message = apiError.error?.message,
               !message.isEmpty {
                throw ServiceError.api(statusCode: http.statusCode, message: message)
            }

            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError.api(statusCode: http.statusCode, message: body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ServiceError.emptyResponse
        }

        return content
    }

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidResponse
        case api(statusCode: Int, message: String?)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key is missing. Set it in Settings."
            case .missingModel:
                return "OpenAI model is missing. Set model in Settings."
            case .invalidResponse:
                return "Invalid response from OpenAI API."
            case let .api(statusCode, message):
                let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let detail, !detail.isEmpty {
                    return "OpenAI API error (\(statusCode)): \(detail)"
                }
                return "OpenAI API error (\(statusCode))."
            case .emptyResponse:
                return "OpenAI returned an empty result."
            }
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}
