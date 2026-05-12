# IKMacros Bridge

**Canonical source: [`ikame-ios-coding/references/api-ikmacros.md`](../../ikame-ios-coding/references/api-ikmacros.md)** — `@APIProtocol`, `@JsonSerializable`, `@JsonKey`, `=>` operator, registry pattern, field mapping. This file holds only the figma-specific delta.

Applies only when `c1-conventions.json.usesIKMacros == true` AND the run generates networking code (most Figma-to-SwiftUI tasks are UI-only — this file rarely fires).

## §1. Detection (C1 audit)

`usesIKMacros = true` when any signal: `import IKMacros`; `@APIProtocol(` / `@JsonSerializable` in any file; `pod 'IKMacros'` or umbrella `pod 'IKCoreApp'`; `IKAPIRepository` conformance; `enum API` registry file.

C1 also captures `apiRegistry`:
- `registryEnumName` (e.g. `API`)
- `registryFilePath` (e.g. `Core/Network/API.swift`)
- `sharedRepoExpr` (e.g. `sharedRepo`, `AppAPIRepository.shared`) — expression used to instantiate `<Domain>RepositoryImpl(repo:)`

If absent → emit plain `Codable` DTOs and a hand-written `URLSession` client. Do NOT introduce IKMacros to a project that doesn't have it.

## §2. Figma-driven DTO ↔ Entity mapping

When Figma drives the data shape (e.g. "this list of articles needs a title, author, image"), the skill emits:

1. **DTO** in `Core/Network/Models/<Domain>DTO.swift` — mirrors API JSON, uses `@JsonSerializable` + `@JsonKey`. See canonical for the full pattern.
2. **Entity** in `Entities/<Domain>.swift` — what the View consumes (no `DTO` suffix). Maps FROM DTO via converter.
3. **Converter** in DTO file:

```swift
extension ArticleDTO {
    func toEntity() -> Article {
        Article(
            id: id,
            title: title,
            authorName: authorName,
            imageURL: URL(string: thumbnailUrl),
            publishedAt: ISO8601DateFormatter().date(from: publishedAt) ?? .distantPast
        )
    }
}
```

The View only sees `Article` (Entity); ViewModel does the `dto.toEntity()` mapping. This way the Entity shape is driven by Figma needs, not API quirks.

## §3. Extending existing registry

When adding a new repository, **extend** the existing `enum API` — never instantiate `<Domain>RepositoryImpl(...)` outside it:

```swift
// API.swift (existing — skill adds new property)
enum API {
    static var articleRepository: any ArticleRepository {
        ArticleRepositoryImpl(repo: sharedRepo)
    }
+   static var commentRepository: any CommentRepository {           // ← skill adds
+       CommentRepositoryImpl(repo: sharedRepo)
+   }
    private static let sharedRepo: IKAPIRepository = ...
}
```

C1 captures `apiRegistry.registryFilePath` + `sharedRepoExpr` so the skill emits the matching shape.

**Banned:** instantiating `XxxRepositoryImpl(...)` directly in a ViewModel or in `enum API` with a different shared-repo expression than C1 detected.

## §4. ViewModel dependency injection

```swift
@MainActor
final class ArticleListViewModel: ObservableObject {
    private let articleRepository: any ArticleRepository

    init(articleRepository: any ArticleRepository = API.articleRepository) {
        self.articleRepository = articleRepository
    }
    // ... use `articleRepository.getArticles(...)`
}
```

Default value `= API.<accessor>` allows testing with a mock. Never use `API.articleRepository` mid-method.
