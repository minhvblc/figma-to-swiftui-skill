import Foundation
import SwiftSyntax

// AuditVisitor — walks a SwiftUI source file and emits AuditRow per
// (color, font, padding, spacing, frame, image, text, stack) it recognizes.
//
// Coverage philosophy: pragmatic, not exhaustive. Anything we can't classify
// gets counted toward unknownModifierCount; the L2 trace script uses the
// counter to decide whether the audit is trustworthy.

final class AuditVisitor: SyntaxVisitor {
    var rows: [AuditRow] = []
    var unknownNodeTypes: Set<String> = []
    var unknownModifierCount: Int = 0
    var totalViewDecls: Int = 0
    var knownModifierCount: Int = 0

    private let converter: SourceLocationConverter
    private let fileBaseName: String

    static let viewConstructors: Set<String> = [
        "Color", "Image", "Text", "Label",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack",
        "Button", "Capsule", "Circle", "Rectangle", "RoundedRectangle", "Ellipse",
        "ScrollView", "List", "Form", "Section",
        "NavigationStack", "NavigationView", "NavigationLink",
        "TabView", "Picker", "Slider", "Stepper", "DatePicker",
        "Toggle", "TextField", "SecureField",
        "Spacer", "Divider", "Group", "EmptyView",
    ]

    // Visual / layout modifiers we extract structured info from.
    static let knownModifiers: Set<String> = [
        "padding", "frame",
        "foregroundStyle", "foregroundColor", "background", "tint",
        "fill", "stroke", "border", "shadow",
        "font", "ikFont", "appFont",
        "fontWeight", "fontDesign", "tracking", "kerning", "lineSpacing",
        "cornerRadius", "clipShape",
        "resizable", "scaledToFit", "scaledToFill", "aspectRatio", "renderingMode",
        "opacity", "blendMode", "blur", "mask",
        "multilineTextAlignment", "lineLimit",
        "ignoresSafeArea", "safeAreaInset", "safeAreaPadding",
        // Nav-bar visibility — captured so c3-safearea-gate.sh NB-1 can flag
        // NavigationStack/View wrappers that don't explicitly hide the system
        // nav bar when the Figma frame uses a custom top bar.
        "toolbar", "toolbarVisibility", "toolbarBackground",
        "navigationBarHidden", "navigationBarBackButtonHidden",
        "navigationTitle", "navigationBarTitleDisplayMode",
    ]

    // Modifiers that touch styling but we don't emit a row for (mark known but
    // skip structured extraction).
    static let knownButNoRowModifiers: Set<String> = [
        "resizable", "scaledToFit", "scaledToFill", "aspectRatio",
        "multilineTextAlignment", "lineLimit", "fontDesign", "renderingMode",
    ]

    init(converter: SourceLocationConverter, fileBaseName: String) {
        self.converter = converter
        self.fileBaseName = fileBaseName
        super.init(viewMode: .sourceAccurate)
    }

    private func loc(_ node: some SyntaxProtocol) -> (line: Int, col: Int) {
        let l = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return (l.line, l.column)
    }

    /// Line/col of the modifier name itself in `<expr>.modifier(args)`.
    /// Fixes the "modifier on a multi-line chain reports the chain's start line"
    /// bug — without this, every modifier on a VStack body would report the
    /// VStack's line.
    private func modifierCallSite(_ node: FunctionCallExprSyntax) -> (line: Int, col: Int) {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            return loc(member.declName)
        }
        return loc(node)
    }

    /// Compact literal for a modifier call site — drops the base expression
    /// (which can be the entire VStack body), keeping just `.modifier(args)`.
    private func modifierLiteral(_ node: FunctionCallExprSyntax) -> String {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            let args = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return ".\(name)(\(args))"
        }
        return node.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact literal for a constructor call — drops the trailing closure body
    /// (e.g. VStack's content), keeping just `Name(args)`.
    private func constructorLiteral(_ node: FunctionCallExprSyntax, name: String) -> String {
        let args = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name)(\(args))"
    }

    private func makeID(kind: String, line: Int) -> String {
        "\(kind)-\(fileBaseName)-L\(line)"
    }

    // MARK: - StructDecl tracker

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let inheritsView = node.inheritanceClause?.inheritedTypes.contains { inherit in
            if let ident = inherit.type.as(IdentifierTypeSyntax.self),
               ident.name.text == "View" {
                return true
            }
            return false
        } ?? false
        if inheritsView { totalViewDecls += 1 }
        return .visitChildren
    }

    // MARK: - FunctionCall (constructors + modifiers)

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpr = node.calledExpression

        // Case A: `Name(...)` — constructor (Color, Image, VStack, …)
        if let identExpr = calledExpr.as(DeclReferenceExprSyntax.self) {
            let name = identExpr.baseName.text
            if Self.viewConstructors.contains(name) {
                processConstructor(name: name, node: node)
                knownModifierCount += 1
                return .visitChildren
            }
            return .visitChildren
        }

        // Case B: `expr.method(...)` — modifier call
        if let memberExpr = calledExpr.as(MemberAccessExprSyntax.self) {
            // Only count when there IS a base (so `.padding(...)` standalone
            // member access isn't a modifier — it's `.padding` value).
            guard memberExpr.base != nil else {
                return .visitChildren
            }
            let methodName = memberExpr.declName.baseName.text

            if Self.knownModifiers.contains(methodName) {
                if !Self.knownButNoRowModifiers.contains(methodName) {
                    processModifier(name: methodName, node: node, member: memberExpr)
                }
                knownModifierCount += 1
                return .visitChildren
            }

            // Unknown modifier — only count when base looks like a View chain
            // (FunctionCallExpr returning View OR another modifier chain).
            // Skips `viewModel.send(.submit)`, `someStruct.method()`, etc.,
            // which would otherwise pollute the unknownModifierCount budget.
            if let first = methodName.first, first.isLowercase,
               isProbablyViewBase(memberExpr.base) {
                unknownModifierCount += 1
                unknownNodeTypes.insert(".\(methodName)")
            }
        }

        return .visitChildren
    }

    /// Heuristic: is this expression probably the base of a SwiftUI modifier
    /// chain (i.e. it's a View)? Used to avoid counting non-view method calls
    /// like `viewModel.send(.submit)` toward unknownModifierCount.
    private func isProbablyViewBase(_ expr: ExprSyntax?) -> Bool {
        guard let expr = expr else { return false }
        // Another modifier chain (FunctionCallExpr with MemberAccess callee)
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
               callee.base != nil {
                return true
            }
            // Top-level view constructor
            if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self),
               Self.viewConstructors.contains(ident.baseName.text) {
                return true
            }
        }
        return false
    }

    // MARK: - Constructor dispatch

    private func processConstructor(name: String, node: FunctionCallExprSyntax) {
        switch name {
        case "Color":
            emitColorConstructor(node: node)
        case "Image":
            emitImageConstructor(node: node)
        case "Text", "Label":
            emitTextConstructor(node: node, kind: name)
        case "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack",
             "NavigationStack", "NavigationView", "ScrollView":
            // NavigationStack/NavigationView emitted so c3-safearea-gate.sh
            // NB-1 can detect "this file wraps content in a NavigationStack
            // — does it also hide the toolbar?". ScrollView is captured so
            // SA-2 can check fullbleed root patterns.
            emitStackConstructor(node: node, name: name)
        default:
            break
        }
    }

    // MARK: - Modifier dispatch

    private func processModifier(name: String, node: FunctionCallExprSyntax, member: MemberAccessExprSyntax) {
        switch name {
        case "padding":
            emitPadding(node: node)
        case "frame":
            emitFrame(node: node)
        case "foregroundStyle", "foregroundColor", "tint", "background", "fill":
            emitColorModifier(node: node, modName: name)
        case "font", "ikFont", "appFont":
            emitFont(node: node, modName: name, member: member)
        case "fontWeight":
            emitFontWeight(node: node, member: member)
        case "tracking", "kerning", "lineSpacing":
            emitFontSubAxis(node: node, axisName: name, member: member)
        case "cornerRadius":
            emitCornerRadius(node: node)
        case "clipShape":
            emitClipShape(node: node)
        case "shadow":
            emitShadow(node: node)
        case "border":
            emitBorder(node: node)
        case "stroke":
            emitStroke(node: node)
        case "opacity":
            emitOpacity(node: node)
        case "blur":
            emitBlur(node: node)
        case "blendMode":
            emitBlendMode(node: node)
        case "mask":
            // Mask takes a closure, skip structured extraction for MVP
            break
        case "ignoresSafeArea", "safeAreaInset", "safeAreaPadding":
            emitSafeArea(node: node, modName: name, member: member)
        case "toolbar", "toolbarVisibility", "toolbarBackground",
             "navigationBarHidden", "navigationBarBackButtonHidden",
             "navigationTitle", "navigationBarTitleDisplayMode":
            emitNavBar(node: node, modName: name, member: member)
        default:
            break
        }
    }

    // MARK: - Color

    private func emitColorConstructor(node: FunctionCallExprSyntax) {
        let (line, col) = loc(node)
        let literal = constructorLiteral(node, name: "Color")
        let nodeIdHint = trailingNodeIdHint(for: node)

        // Cases:
        //   Color(.someToken)        — tokenRef
        //   Color("name")            — literal string (banned per skill)
        //   Color(red:green:blue:)   — literal rgb
        //   Color(uiColor: ...)      — literal raw (UIKit conversion)
        if let firstArg = node.arguments.first {
            // First-arg expression analysis
            if firstArg.label == nil,
               let mem = firstArg.expression.as(MemberAccessExprSyntax.self),
               mem.base == nil {
                // Color(.tokenName)
                var v = AuditValue(form: "tokenRef")
                v.name = mem.declName.baseName.text
                let row = AuditRow(
                    id: makeID(kind: "color", line: line),
                    line: line, col: col, kind: "color", scope: "init",
                    ownerType: "Color",
                    literal: literal, value: v,
                    claim: AuditClaim(tokenLookup: v.name, nodeIdHint: nodeIdHint),
                    chain: nil, branchPath: nil
                )
                rows.append(row)
                return
            }
            if firstArg.label == nil,
               let str = firstArg.expression.as(StringLiteralExprSyntax.self) {
                // Color("name") — literal-string asset-catalog form (banned per skill)
                var v = AuditValue(form: "literal")
                v.name = stringLiteralValue(str)
                let row = AuditRow(
                    id: makeID(kind: "color", line: line),
                    line: line, col: col, kind: "color", scope: "init",
                    ownerType: "Color",
                    literal: literal, value: v,
                    claim: AuditClaim(nodeIdHint: nodeIdHint),
                    chain: nil, branchPath: nil
                )
                rows.append(row)
                return
            }
            // Color(red:green:blue:) / Color(uiColor:)
            var v = AuditValue(form: "literal")
            v.raw = node.arguments.description
            let row = AuditRow(
                id: makeID(kind: "color", line: line),
                line: line, col: col, kind: "color", scope: "init",
                ownerType: "Color",
                literal: literal, value: v,
                claim: AuditClaim(nodeIdHint: nodeIdHint),
                chain: nil, branchPath: nil
            )
            rows.append(row)
        }
    }

    private func emitColorModifier(node: FunctionCallExprSyntax, modName: String) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        guard let firstArg = node.arguments.first else { return }
        let expr = firstArg.expression

        // Detect non-color fills first (gradient, image). These get kind=fill
        // so L2 can match against fills.json instead of tokens.json.
        if let fnCall = expr.as(FunctionCallExprSyntax.self),
           let calleeIdent = fnCall.calledExpression.as(DeclReferenceExprSyntax.self) {
            let calleeName = calleeIdent.baseName.text
            switch calleeName {
            case "LinearGradient", "RadialGradient", "AngularGradient", "EllipticalGradient":
                emitFillModifier(node: node, modName: modName, gradientKind: calleeName)
                return
            case "Image":
                emitFillModifier(node: node, modName: modName, gradientKind: "image")
                return
            default:
                break
            }
        }

        // .foregroundStyle(.tint) / .tint(.accentColor) / .background(Color.X) / .foregroundColor(Color.appBackground)
        var v = AuditValue(form: "literal")
        v.raw = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)

        if let mem = expr.as(MemberAccessExprSyntax.self) {
            if mem.base == nil {
                // .tint / .accentColor — implicit Color extension
                v = AuditValue(form: "tokenRef")
                v.name = mem.declName.baseName.text
            } else if let base = mem.base?.as(DeclReferenceExprSyntax.self),
                      base.baseName.text == "Color" {
                // Color.appBackground
                v = AuditValue(form: "tokenRef")
                v.name = mem.declName.baseName.text
            }
        } else if let fnCall = expr.as(FunctionCallExprSyntax.self),
                  let identCallee = fnCall.calledExpression.as(DeclReferenceExprSyntax.self),
                  identCallee.baseName.text == "Color" {
            // .foregroundStyle(Color(.tokenName)) — recurse
            if let inner = fnCall.arguments.first,
               inner.label == nil,
               let innerMem = inner.expression.as(MemberAccessExprSyntax.self),
               innerMem.base == nil {
                v = AuditValue(form: "tokenRef")
                v.name = innerMem.declName.baseName.text
            }
        }

        let row = AuditRow(
            id: makeID(kind: "color", line: line),
            line: line, col: col, kind: "color", scope: "modifier",
            ownerType: modName,
            literal: literal, value: v,
            claim: AuditClaim(tokenLookup: v.name, nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    /// Emits a `kind: "fill"` row for `.background(LinearGradient(...))`,
    /// `.background(RadialGradient(...))`, `.background(AngularGradient(...))`,
    /// `.background(Image(...))`. L2 trace matches these against fills.json
    /// rather than tokens.json.
    private func emitFillModifier(node: FunctionCallExprSyntax, modName: String, gradientKind: String) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        // For now, store the kind string in `preset` (re-used field) and full
        // expression in `raw`. L2 parses these out.
        v.preset = gradientKind
        v.raw = (node.arguments.first?.expression.description ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let row = AuditRow(
            id: makeID(kind: "fill", line: line),
            line: line, col: col, kind: "fill", scope: "modifier",
            ownerType: modName,
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Image

    private func emitImageConstructor(node: FunctionCallExprSyntax) {
        let (line, col) = loc(node)
        let literal = constructorLiteral(node, name: "Image")
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        var ownerType = "Image"

        if let firstArg = node.arguments.first {
            // Image(systemName: "name") — system glyph
            if firstArg.label?.text == "systemName",
               let str = firstArg.expression.as(StringLiteralExprSyntax.self) {
                v = AuditValue(form: "systemNamedAllowed")
                v.systemName = stringLiteralValue(str)
            }
            // Image(.assetName) — asset-symbol form (iOS 17+)
            else if firstArg.label == nil,
                    let mem = firstArg.expression.as(MemberAccessExprSyntax.self),
                    mem.base == nil {
                v = AuditValue(form: "assetRef")
                v.name = mem.declName.baseName.text
            }
            // Image("name") — string asset-catalog form (banned per skill)
            else if firstArg.label == nil,
                    let str = firstArg.expression.as(StringLiteralExprSyntax.self) {
                v = AuditValue(form: "literal")
                v.name = stringLiteralValue(str)
            }
            // Image(decorative: "...") / Image(uiImage:) / etc.
            else {
                v = AuditValue(form: "literal")
                v.raw = node.arguments.description
            }
        }

        let row = AuditRow(
            id: makeID(kind: "image", line: line),
            line: line, col: col, kind: "image", scope: "init",
            ownerType: ownerType,
            literal: literal, value: v,
            claim: AuditClaim(registryEntry: v.name, nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Text / Label

    private func emitTextConstructor(node: FunctionCallExprSyntax, kind: String) {
        let (line, col) = loc(node)
        let literal = constructorLiteral(node, name: kind)
        let nodeIdHint = trailingNodeIdHint(for: node)

        guard let firstArg = node.arguments.first else { return }

        var v = AuditValue(form: "literal")

        if let str = firstArg.expression.as(StringLiteralExprSyntax.self) {
            v.text = stringLiteralValue(str)
            v.form = "literal"
        } else if let mem = firstArg.expression.as(MemberAccessExprSyntax.self),
                  let base = mem.base?.as(DeclReferenceExprSyntax.self) {
            // Text(Strings.Onboarding.title) — computed via enum reference
            v.form = "computed"
            v.raw = "\(base.baseName.text).\(mem.declName.baseName.text)"
        } else {
            v.form = "computed"
            v.raw = firstArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let row = AuditRow(
            id: makeID(kind: "text", line: line),
            line: line, col: col, kind: "text", scope: "init",
            ownerType: kind,
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Stack

    private func emitStackConstructor(node: FunctionCallExprSyntax, name: String) {
        let (line, col) = loc(node)
        let literal = constructorLiteral(node, name: name)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        v.stackKind = name

        for arg in node.arguments {
            if let label = arg.label?.text {
                switch label {
                case "spacing":
                    if let d = extractDouble(from: arg.expression) {
                        v.spacing = d
                    }
                case "alignment":
                    v.alignment = extractAlignment(from: arg.expression)
                default:
                    break
                }
            }
        }

        let row = AuditRow(
            id: makeID(kind: "stack", line: line),
            line: line, col: col, kind: "stack", scope: "init",
            ownerType: name,
            literal: shortenLiteral(literal),
            value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Padding

    private func emitPadding(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        v.edge = "all"

        let argsArr = Array(node.arguments)

        if argsArr.isEmpty {
            // .padding() — default system padding
            v.edge = "all"
            v.raw = "default"
        } else if argsArr.count == 1 {
            let arg = argsArr[0]
            if let d = extractDouble(from: arg.expression) {
                v.amount = d
                v.edge = "all"
            } else if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                // .padding(.horizontal) — edge only, no amount
                v.edge = mem.declName.baseName.text
            } else {
                v.raw = arg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if argsArr.count >= 2 {
            // .padding(.horizontal, 16) / .padding(.top, 24)
            let first = argsArr[0]
            let second = argsArr[1]
            if let mem = first.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                v.edge = mem.declName.baseName.text
            }
            if let d = extractDouble(from: second.expression) {
                v.amount = d
            }
        }

        let row = AuditRow(
            id: makeID(kind: "padding", line: line),
            line: line, col: col, kind: "padding", scope: "modifier",
            ownerType: "padding",
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Frame

    private func emitFrame(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")

        for arg in node.arguments {
            switch arg.label?.text {
            case "width":
                if let d = extractDouble(from: arg.expression) { v.width = d }
            case "height":
                if let d = extractDouble(from: arg.expression) { v.height = d }
            case "maxWidth":
                if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil,
                   mem.declName.baseName.text == "infinity" {
                    v.maxWidth = ".infinity"
                } else if let d = extractDouble(from: arg.expression) {
                    v.maxWidth = "\(d)"
                }
            case "maxHeight":
                if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil,
                   mem.declName.baseName.text == "infinity" {
                    v.maxHeight = ".infinity"
                } else if let d = extractDouble(from: arg.expression) {
                    v.maxHeight = "\(d)"
                }
            case "alignment":
                v.alignment = extractAlignment(from: arg.expression)
            default:
                break
            }
        }

        let row = AuditRow(
            id: makeID(kind: "frame", line: line),
            line: line, col: col, kind: "frame", scope: "modifier",
            ownerType: "frame",
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Font

    private func emitFont(node: FunctionCallExprSyntax, modName: String, member: MemberAccessExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        v.textHint = findTextInChain(member)

        guard let arg = node.arguments.first else { return }
        let expr = arg.expression

        if let mem = expr.as(MemberAccessExprSyntax.self), mem.base == nil {
            // .font(.body) / .ikFont(.bodySemi) / .appFont(.title)
            v.form = "tokenRef"
            v.preset = mem.declName.baseName.text
        } else if let call = expr.as(FunctionCallExprSyntax.self),
                  let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
                  callee.base == nil {
            // .font(.system(size: 24, weight: .bold)) — call to .system / .custom
            let kind = callee.declName.baseName.text
            v.form = "literal"
            v.preset = kind
            for inner in call.arguments {
                switch inner.label?.text {
                case "size":
                    if let d = extractDouble(from: inner.expression) { v.size = d }
                case "weight":
                    v.weight = extractMemberName(from: inner.expression)
                default:
                    break
                }
            }
        } else if let call = expr.as(FunctionCallExprSyntax.self),
                  let identCallee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            // .ikFont(16, weight: .semibold) — function-form preset call
            v.preset = identCallee.baseName.text
            // First unlabeled arg may be size
            for inner in call.arguments {
                if inner.label == nil, let d = extractDouble(from: inner.expression) {
                    if v.size == nil { v.size = d }
                } else if inner.label?.text == "weight" {
                    v.weight = extractMemberName(from: inner.expression)
                } else if inner.label?.text == "size", let d = extractDouble(from: inner.expression) {
                    v.size = d
                }
            }
        } else {
            v.raw = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let row = AuditRow(
            id: makeID(kind: "font", line: line),
            line: line, col: col, kind: "font", scope: "modifier",
            ownerType: modName,
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitFontWeight(node: FunctionCallExprSyntax, member: MemberAccessExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.textHint = findTextInChain(member)
        if let arg = node.arguments.first {
            v.weight = extractMemberName(from: arg.expression) ?? arg.expression.description
        }
        let row = AuditRow(
            id: makeID(kind: "font", line: line),
            line: line, col: col, kind: "font", scope: "modifier",
            ownerType: "fontWeight",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitFontSubAxis(node: FunctionCallExprSyntax, axisName: String, member: MemberAccessExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.textHint = findTextInChain(member)
        if let arg = node.arguments.first, let d = extractDouble(from: arg.expression) {
            v.amount = d
        }
        let row = AuditRow(
            id: makeID(kind: "font", line: line),
            line: line, col: col, kind: "font", scope: "modifier",
            ownerType: axisName,
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Safe area

    /// Emits a `kind: "safearea"` row for `.ignoresSafeArea(...)`, `.safeAreaInset(...)`,
    /// or `.safeAreaPadding(...)`. L2 / c3-safearea-gate.sh cross-references these
    /// rows against inventory CONTAINER (mockupChrome, stickyBottom) to flag misuse:
    ///   - `.ignoresSafeArea()` applied to a content target (ScrollView/VStack
    ///     containing primary content) instead of background sibling
    ///   - missing `.safeAreaInset(edge: .bottom)` when inventory shows sticky bottom CTA
    ///   - ScrollView at root without background `.ignoresSafeArea(edges: .top)`
    private func emitSafeArea(node: FunctionCallExprSyntax, modName: String, member: MemberAccessExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        v.target = findTargetConstructorName(member)

        // Parse `edges` argument:
        //   .ignoresSafeArea()                — no arg → "all" (SwiftUI default)
        //   .ignoresSafeArea(edges: .top)     — single edge
        //   .ignoresSafeArea(.all, edges: .top) — first regions arg + edges
        //   .safeAreaInset(edge: .bottom) { ... } — single `edge` (note: singular for inset)
        //   .safeAreaPadding(.horizontal, N)  — Edge.Set arg
        var edges: String?
        for arg in node.arguments {
            switch arg.label?.text {
            case "edges", "edge":
                if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                    edges = "." + mem.declName.baseName.text
                } else {
                    edges = arg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case nil:
                // First positional arg might be .all / .horizontal / .top etc.
                if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil, edges == nil {
                    edges = "." + mem.declName.baseName.text
                }
            default:
                break
            }
        }
        if edges == nil && modName == "ignoresSafeArea" {
            // SwiftUI default when called with no args is .all
            edges = ".all"
        }
        v.edges = edges

        let row = AuditRow(
            id: makeID(kind: "safearea", line: line),
            line: line, col: col, kind: "safearea", scope: "modifier",
            ownerType: modName,
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Navigation bar visibility

    /// Emits a `kind: "navbar"` row for `.toolbar(...)`, `.toolbarVisibility(...)`,
    /// `.navigationBarHidden(...)`, `.navigationTitle(...)`, etc. The
    /// c3-safearea-gate.sh NB-1 rule cross-references these against the
    /// `NavigationStack`/`NavigationView` target in the chain — when a screen
    /// is wrapped in NavigationStack but no toolbar-hide modifier is in scope,
    /// the system nav bar adds ~44pt above the content, breaking fidelity with
    /// Figma screens that use a custom top bar.
    ///
    /// Visibility extraction:
    ///   - `.toolbar(.hidden, for: .navigationBar)` → visibility=hidden, surface=navigationBar
    ///   - `.toolbarVisibility(.hidden, for: .navigationBar)` → same shape
    ///   - `.navigationBarHidden(true)` (legacy) → visibility=hidden, surface=navigationBar
    ///   - `.navigationTitle("…")` / `.navigationBarTitleDisplayMode(.inline)` →
    ///     visibility=shown (caller relies on nav bar)
    private func emitNavBar(node: FunctionCallExprSyntax, modName: String, member: MemberAccessExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        let nodeIdHint = trailingNodeIdHint(for: node)

        var v = AuditValue(form: "literal")
        v.target = findTargetConstructorName(member)

        var visibility: String?
        var surface: String?

        switch modName {
        case "toolbar", "toolbarVisibility":
            // First arg: visibility (.hidden / .visible / .automatic)
            // Second arg (labelled `for:`): surface (.navigationBar / .bottomBar / .tabBar)
            // For `toolbar` with closure form `{ ToolbarItem(...) }` we don't get
            // a visibility/for tuple — that's the "show toolbar with items" form
            // and treats as visibility=shown.
            var foundVisibility = false
            for arg in node.arguments {
                switch arg.label?.text {
                case "for":
                    if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                        surface = "." + mem.declName.baseName.text
                    }
                case nil:
                    if !foundVisibility,
                       let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                        let vis = mem.declName.baseName.text
                        if vis == "hidden" || vis == "visible" || vis == "automatic" {
                            visibility = vis
                            foundVisibility = true
                        }
                    }
                default:
                    break
                }
            }
            // No visibility arg → toolbar with content closure → visibility=shown
            if visibility == nil && node.trailingClosure != nil {
                visibility = "visible"
                surface = surface ?? ".navigationBar"
            }
        case "toolbarBackground":
            // Either `.toolbarBackground(<ShapeStyle>, for: <surface>)` or
            // `.toolbarBackground(<Visibility>, for: <surface>)`. Treat as
            // visibility-shown (caller is decorating the bar) unless first arg
            // is .hidden.
            for arg in node.arguments {
                switch arg.label?.text {
                case "for":
                    if let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                        surface = "." + mem.declName.baseName.text
                    }
                case nil:
                    if visibility == nil,
                       let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil,
                       mem.declName.baseName.text == "hidden" {
                        visibility = "hidden"
                    }
                default:
                    break
                }
            }
            visibility = visibility ?? "visible"
            surface = surface ?? ".navigationBar"
        case "navigationBarHidden":
            visibility = "hidden"  // assume true; rare for someone to write `.navigationBarHidden(false)` defensively
            if let arg = node.arguments.first,
               let bool = arg.expression.as(BooleanLiteralExprSyntax.self) {
                visibility = (bool.literal.text == "true") ? "hidden" : "visible"
            }
            surface = ".navigationBar"
        case "navigationBarBackButtonHidden":
            // Doesn't toggle nav-bar visibility itself — emit row so gate can
            // see the agent is interacting with the nav bar.
            visibility = "shown-no-back"
            surface = ".navigationBar"
        case "navigationTitle":
            // Setting a title implies the nav bar is shown (default behavior).
            visibility = "visible"
            surface = ".navigationBar"
            if let arg = node.arguments.first,
               let str = arg.expression.as(StringLiteralExprSyntax.self) {
                v.text = stringLiteralValue(str)
            }
        case "navigationBarTitleDisplayMode":
            // Same — agent set a display mode → nav bar is intentional.
            visibility = "visible"
            surface = ".navigationBar"
            if let arg = node.arguments.first,
               let mem = arg.expression.as(MemberAccessExprSyntax.self), mem.base == nil {
                v.preset = mem.declName.baseName.text  // inline / large / automatic
            }
        default:
            break
        }

        v.preset = v.preset ?? visibility
        v.edges = surface  // re-use the edges field for surface — keeps schema flat

        let row = AuditRow(
            id: makeID(kind: "navbar", line: line),
            line: line, col: col, kind: "navbar", scope: "modifier",
            ownerType: modName,
            literal: literal, value: v,
            claim: AuditClaim(nodeIdHint: nodeIdHint),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    /// Walk down `base.calledExpression` from a modifier's MemberAccessExpr,
    /// returning the innermost `Text("…")` literal string. Returns nil when the
    /// chain doesn't bottom out in a Text constructor (e.g. modifier on VStack).
    /// Used by font/spacing modifiers so L2 can bridge to typography-perline.
    private func findTextInChain(_ memberExpr: MemberAccessExprSyntax) -> String? {
        var current: ExprSyntax? = memberExpr.base
        var depth = 0
        while let expr = current, depth < 12 {
            depth += 1
            if let call = expr.as(FunctionCallExprSyntax.self) {
                // Found a constructor — check if it's Text
                if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   ident.baseName.text == "Text",
                   let firstArg = call.arguments.first,
                   let str = firstArg.expression.as(StringLiteralExprSyntax.self) {
                    return stringLiteralValue(str)
                }
                // Member access — peer down through the chain
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    current = member.base
                    continue
                }
            }
            return nil
        }
        return nil
    }

    /// Walk down chain from a modifier's MemberAccessExpr, returning the innermost
    /// constructor name (e.g. "ScrollView", "VStack", "Color", "Image"). Used by
    /// safe-area gate to flag `.ignoresSafeArea()` applied to content targets.
    private func findTargetConstructorName(_ memberExpr: MemberAccessExprSyntax) -> String? {
        var current: ExprSyntax? = memberExpr.base
        var depth = 0
        while let expr = current, depth < 12 {
            depth += 1
            if let call = expr.as(FunctionCallExprSyntax.self) {
                if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    return ident.baseName.text
                }
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    current = member.base
                    continue
                }
            }
            return nil
        }
        return nil
    }

    // MARK: - Corner radius / shape / shadow / etc.

    private func emitCornerRadius(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        if let arg = node.arguments.first, let d = extractDouble(from: arg.expression) {
            v.amount = d
        }
        let row = AuditRow(
            id: makeID(kind: "frame", line: line),
            line: line, col: col, kind: "frame", scope: "modifier",
            ownerType: "cornerRadius",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitClipShape(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        if let arg = node.arguments.first {
            v.raw = arg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let row = AuditRow(
            id: makeID(kind: "frame", line: line),
            line: line, col: col, kind: "frame", scope: "modifier",
            ownerType: "clipShape",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitShadow(node: FunctionCallExprSyntax) {
        // shadow is fully captured by L3 — emit row with raw args
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.raw = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = AuditRow(
            id: makeID(kind: "frame", line: line),
            line: line, col: col, kind: "frame", scope: "modifier",
            ownerType: "shadow",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitBorder(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.raw = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = AuditRow(
            id: makeID(kind: "color", line: line),
            line: line, col: col, kind: "color", scope: "modifier",
            ownerType: "border",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitStroke(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.raw = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = AuditRow(
            id: makeID(kind: "color", line: line),
            line: line, col: col, kind: "color", scope: "modifier",
            ownerType: "stroke",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitOpacity(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        if let arg = node.arguments.first, let d = extractDouble(from: arg.expression) {
            v.amount = d
        }
        let row = AuditRow(
            id: makeID(kind: "color", line: line),
            line: line, col: col, kind: "color", scope: "modifier",
            ownerType: "opacity",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitBlur(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        v.raw = node.arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = AuditRow(
            id: makeID(kind: "frame", line: line),
            line: line, col: col, kind: "frame", scope: "modifier",
            ownerType: "blur",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    private func emitBlendMode(node: FunctionCallExprSyntax) {
        let (line, col) = modifierCallSite(node)
        let literal = modifierLiteral(node)
        var v = AuditValue(form: "literal")
        if let arg = node.arguments.first {
            v.raw = extractMemberName(from: arg.expression) ?? arg.expression.description
        }
        let row = AuditRow(
            id: makeID(kind: "color", line: line),
            line: line, col: col, kind: "color", scope: "modifier",
            ownerType: "blendMode",
            literal: literal, value: v,
            claim: AuditClaim(),
            chain: nil, branchPath: nil
        )
        rows.append(row)
    }

    // MARK: - Helpers

    private func extractDouble(from expr: ExprSyntax) -> Double? {
        if let i = expr.as(IntegerLiteralExprSyntax.self) {
            return Double(i.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let f = expr.as(FloatLiteralExprSyntax.self) {
            return Double(f.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        // Negative numbers: -16 is PrefixOperatorExpr
        if let pre = expr.as(PrefixOperatorExprSyntax.self),
           pre.operator.text == "-",
           let inner = extractDouble(from: pre.expression) {
            return -inner
        }
        return nil
    }

    private func extractMemberName(from expr: ExprSyntax) -> String? {
        if let mem = expr.as(MemberAccessExprSyntax.self) {
            return mem.declName.baseName.text
        }
        return nil
    }

    private func extractAlignment(from expr: ExprSyntax) -> String? {
        if let mem = expr.as(MemberAccessExprSyntax.self) {
            return mem.declName.baseName.text
        }
        return nil
    }

    private func stringLiteralValue(_ str: StringLiteralExprSyntax) -> String {
        var parts: [String] = []
        for seg in str.segments {
            if let s = seg.as(StringSegmentSyntax.self) {
                parts.append(s.content.text)
            } else {
                parts.append("\\(<interp>)")
            }
        }
        return parts.joined()
    }

    private func trailingNodeIdHint(for node: some SyntaxProtocol) -> String? {
        // Look for `// Figma: nodeId=<id>` or `// figma: <id>` in trailing trivia
        // of the node or its parent line.
        let trivia = node.trailingTrivia
        for piece in trivia {
            if case .lineComment(let text) = piece {
                if let match = parseNodeIdComment(text) {
                    return match
                }
            }
        }
        // Also check leading trivia of next sibling (common case: comment on its own line above)
        return nil
    }

    private func parseNodeIdComment(_ text: String) -> String? {
        // // Figma: 1234:5678
        // // figma: nodeId=1234:5678
        // // Figma: node 1234:5678
        let lower = text.lowercased()
        guard lower.contains("figma") else { return nil }
        // Match a Figma node-id pattern: digits:digits
        let pattern = #"(\d+:\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(m.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }

    private func shortenLiteral(_ s: String) -> String {
        // Stack constructors have huge bodies — trim to first 80 chars + "…" for readability
        if s.count <= 80 { return s }
        let end = s.index(s.startIndex, offsetBy: 80)
        return String(s[..<end]) + "…"
    }
}
