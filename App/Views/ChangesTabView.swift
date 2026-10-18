import SwiftUI

/// Everything the next copy will do. Choices are kept per file and applied to
/// a fresh copy of the original in a fixed order, so none can undo another.
struct ChangesTabView: View {
    @Bindable var store: AppStore
    let job: CleanerJob

    private var preferences: AppPreferences { store.preferences }
    private var disabled: Bool { job.status.isBusy || store.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            if store.copyNeedsUpdate(job) {
                ClayBanner(
                    tone: .warning,
                    title: "Your copy doesn't include these changes yet",
                    message: "Choose Update copy to make a new copy from the original."
                )
            }

            provenanceCard
            if job.inspection?.raw["metadata"]?["available"]?.boolValue == true {
                PropertiesCard(store: store, job: job, disabled: disabled)
            }
            if job.isWordDocument {
                WordTracesCard(store: store, job: job, disabled: disabled)
            }
            PlanSummaryCard(store: store, job: job)
        }
    }

    // MARK: Provenance

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayToggleRow(
                title: "Remove provenance markers",
                detail: provenanceDetail,
                isOn: planBinding(\.removeProvenance),
                identifier: "changes.remove-provenance"
            )
            .disabled(disabled)

            if job.plan.removeProvenance {
                Rectangle().fill(Clay.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: Clay.space4) {
                    ClayToggleRow(
                        title: "Keep ordinary metadata",
                        detail: keepMetadataDetail,
                        isOn: Bindable(preferences).keepNonAIMetadata,
                        identifier: "changes.keep-metadata"
                    )
                    if job.kind == .container {
                        ClayToggleRow(
                            title: "Remove invisible characters in the text",
                            detail: "Zero-width and other hidden Unicode characters in the document's text.",
                            isOn: Bindable(preferences).alsoLayerAText,
                            identifier: "changes.layer-a"
                        )
                    }
                    if job.kind == .text || job.kind == .container {
                        ClayToggleRow(
                            title: "Replace unusual spaces",
                            detail: "Off by default: non-breaking and narrow spaces can be correct typography, for example in French.",
                            isOn: Bindable(preferences).normalizeSpaces,
                            identifier: "changes.normalize-spaces"
                        )
                    }
                    if job.isPDF {
                        pdfImageOptions
                    }
                }
                .disabled(disabled)
                .padding(.leading, Clay.space4)

                Text("These options apply to every file. Set the defaults in Settings.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
        }
        .clayCard()
    }

    private var pdfImageOptions: some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            HStack(spacing: Clay.space3) {
                Text("Images inside the PDF")
                    .font(Clay.bodyMedium)
                    .foregroundStyle(Clay.ink)
                Spacer(minLength: Clay.space3)
                Picker("Images inside the PDF", selection: Bindable(preferences).deepImageMode) {
                    ForEach(AppPreferences.DeepImageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("pdf.deep-image-mode")
            }
            Text(preferences.deepImageMode.explanation + " Rewriting a PDF can affect forms and other interactive features.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let capabilities = store.capabilities, !capabilities.supportsPDFDeepCleaning {
                Label("The image engine isn't available, so only document metadata can be cleaned.", systemImage: "exclamationmark.triangle")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.warning)
            }
        }
    }

    private var provenanceDetail: String {
        switch job.kind {
        case .image: "Content credentials (C2PA) and AI-related metadata in the image."
        case .text: "Invisible characters such as zero-width spaces."
        case .av: "Provenance metadata in the media file."
        case .container, .unknown: "Content credentials, provenance metadata and invisible characters in the document."
        }
    }

    private var keepMetadataDetail: String {
        guard preferences.keepNonAIMetadata else {
            return "Off: all removable metadata is stripped, including camera, location, copyright and descriptive fields."
        }
        if job.isOfficeDocument {
            return "Keeps ordinary details where the format allows. Office files always lose author, last saved by, subject, keywords, description and company; set them again under Document properties."
        }
        return "Keeps camera, date, location and other ordinary details. Only fields related to AI generation or provenance are removed."
    }

    private func planBinding(_ keyPath: WritableKeyPath<JobPlan, Bool>) -> Binding<Bool> {
        Binding(
            get: { job.plan[keyPath: keyPath] },
            set: { value in store.updatePlan(for: job.id) { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Document properties

private struct PropertiesCard: View {
    @Bindable var store: AppStore
    let job: CleanerJob
    let disabled: Bool

    private var metadata: JSONValue? { job.currentInspection?.raw["metadata"] ?? job.inspection?.raw["metadata"] }
    private var fields: [MetadataField] { metadata?["fields"]?.arrayValue?.compactMap(MetadataField.init) ?? [] }
    private var editable: Bool { metadata?["editable"]?.boolValue == true }
    private var edits: [String: String] { job.plan.propertyEdits }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayCardHeader(
                title: "Document properties",
                subtitle: job.stagedOutputURL == nil ? "Values in the original" : "Values in your current copy"
            ) {
                if !edits.isEmpty {
                    Button("Reset all") {
                        store.updatePlan(for: job.id) { $0.propertyEdits = [:] }
                    }
                    .buttonStyle(.clayGhost)
                    .disabled(disabled)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: Clay.space4, verticalSpacing: Clay.space3) {
                ForEach(fields) { field in
                    GridRow(alignment: .center) {
                        Text(field.label)
                            .font(Clay.label)
                            .foregroundStyle(Clay.inkMuted)
                            .gridColumnAlignment(.leading)
                        ClayTextField(label: field.label, text: binding(for: field))
                            .accessibilityIdentifier("metadata.\(field.id)")
                        Group {
                            if edits[field.id] != nil {
                                Button {
                                    store.updatePlan(for: job.id) { $0.propertyEdits[field.id] = nil }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.clayGhost)
                                .help("Undo this change")
                                .accessibilityLabel("Undo change to \(field.label)")
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 36)
                    }
                }
            }
            .disabled(disabled || !editable)

            if !job.plan.propertyEditsAreValid {
                Label("Use at most 4,096 characters per field, without control characters.", systemImage: "exclamationmark.triangle")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.danger)
            }

            VStack(alignment: .leading, spacing: Clay.space1) {
                Text(edits.isEmpty
                     ? "Type to change a value. Leave a field empty to remove it."
                     : "\(edits.count) propert\(edits.count == 1 ? "y" : "ies") will change. An empty field removes that property.")
                if job.isOfficeDocument, job.plan.removeProvenance {
                    Text("Removing provenance clears author, last saved by, subject, keywords and description first. Values you enter here are applied afterwards, so they're kept.")
                }
                if job.isPDF {
                    Text("PDF properties are updated incrementally. Earlier values may still be recoverable, so this isn't a secure way to redact.")
                }
                if let note = metadata?["note"]?.stringValue {
                    Text(note)
                }
            }
            .font(Clay.caption)
            .foregroundStyle(Clay.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .clayCard()
        .accessibilityIdentifier("metadata.card")
    }

    private func binding(for field: MetadataField) -> Binding<String> {
        Binding(
            get: { edits[field.id] ?? field.value },
            set: { value in
                store.updatePlan(for: job.id) { plan in
                    if plan.propertyEdits[field.id] == nil, value == field.value { return }
                    plan.propertyEdits[field.id] = value
                }
            }
        )
    }
}

private struct MetadataField: Identifiable {
    let id: String
    let label: String
    let value: String

    init?(_ raw: JSONValue) {
        guard let id = raw["id"]?.stringValue, let label = raw["label"]?.stringValue else { return nil }
        self.id = id
        self.label = label
        self.value = raw["value"]?.stringValue ?? ""
    }
}

// MARK: - Word editing traces

private struct WordTracesCard: View {
    @Bindable var store: AppStore
    let job: CleanerJob
    let disabled: Bool

    private var preferences: AppPreferences { store.preferences }
    private var inspection: WordTraceInspection? {
        job.inspection?.raw["word_editing_traces"].map(WordTraceInspection.init(raw:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayToggleRow(
                title: "Change Word editing history",
                detail: summary,
                isOn: Binding(
                    get: { job.plan.changeWordTraces },
                    set: { value in store.updatePlan(for: job.id) { $0.changeWordTraces = value } }
                ),
                identifier: "word-traces.enabled"
            )
            .disabled(disabled || inspection?.available != true || inspection?.signed == true)

            if let inspection, inspection.available, job.plan.changeWordTraces {
                Rectangle().fill(Clay.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: Clay.space4) {
                    modePicker("Session IDs", selection: Bindable(preferences).wordSessionMode, id: "word-traces.sessions")
                    modePicker("Recorded dates", selection: Bindable(preferences).wordDateMode, id: "word-traces.dates")
                    if preferences.wordDateMode == .randomize {
                        HStack(spacing: Clay.space3) {
                            Text("Between").font(Clay.body).foregroundStyle(Clay.inkMuted)
                            DatePicker("From", selection: Bindable(preferences).wordDateStart, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .accessibilityIdentifier("word-traces.start")
                            Text("and").font(Clay.body).foregroundStyle(Clay.inkMuted)
                            DatePicker("To", selection: Bindable(preferences).wordDateEnd, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .accessibilityIdentifier("word-traces.end")
                        }
                        Text("New dates keep their original order, and equal times stay equal. Times are in your time zone.")
                            .font(Clay.caption)
                            .foregroundStyle(Clay.inkMuted)
                        if !preferences.wordDateRangeValid {
                            Label("Choose an end date after the start date.", systemImage: "exclamationmark.triangle")
                                .font(Clay.caption)
                                .foregroundStyle(Clay.danger)
                        }
                        if inspection.count("invalidDates") > 0 {
                            Label("\(inspection.count("invalidDates")) dates are empty or malformed. They can be kept or removed, but not randomized.", systemImage: "exclamationmark.triangle")
                                .font(Clay.caption)
                                .foregroundStyle(Clay.warning)
                        }
                    }
                    ClayToggleRow(
                        title: "Reset ZIP entry dates",
                        detail: "Sets the dates of the files inside the package to 1 January 1980. Finder dates and cloud version history aren't affected.",
                        isOn: Bindable(preferences).wordResetArchiveDates,
                        identifier: "word-traces.archive-dates"
                    )
                }
                .disabled(disabled)
                .padding(.leading, Clay.space4)

                ClayDisclosure(title: "What these fields reveal") {
                    VStack(alignment: .leading, spacing: Clay.space2) {
                        Text("Session IDs group edits made between saves. They don't record exact typing times. Randomizing keeps the grouping; removing clears the labels.")
                        Text("Recorded dates include creation, modification and printing, plus dates on revisions and comments.")
                        if inspection.count("datesWithoutTimezone") > 0 {
                            Text("\(inspection.count("datesWithoutTimezone")) dates have no time zone and are treated as UTC.")
                        }
                        Text("Text, formatting, comments, tracked changes and author names are preserved. Opening and saving the copy in Word can add new editing history.")
                    }
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .clayCard()
        .accessibilityIdentifier("word-traces.card")
    }

    private var summary: String {
        guard let inspection else { return "Check the document to read its editing history." }
        guard inspection.available else { return inspection.reason }
        if inspection.signed { return "This document is digitally signed, so its editing history can't be changed." }
        let dates = inspection.count("annotationDates") + inspection.count("documentDates")
        return "\(inspection.count("sessionIDs")) session IDs and \(dates) recorded dates. These show when and in how many sittings the document was edited."
    }

    private func modePicker(_ title: String, selection: Binding<WordTraceMode>, id: String) -> some View {
        HStack(spacing: Clay.space3) {
            Text(title)
                .font(Clay.bodyMedium)
                .foregroundStyle(Clay.ink)
            Spacer(minLength: Clay.space3)
            Picker(title, selection: selection) {
                ForEach(WordTraceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }
}

// MARK: - Summary

private struct PlanSummaryCard: View {
    @Bindable var store: AppStore
    let job: CleanerJob

    var body: some View {
        let steps = store.buildSteps(for: job)
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(title: "Your copy will")
            if steps.isEmpty {
                Text("Choose at least one change above to create a copy.")
                    .font(Clay.body)
                    .foregroundStyle(Clay.inkMuted)
            } else {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Clay.space3) {
                        Text("\(index + 1)")
                            .font(Clay.captionMedium)
                            .monospacedDigit()
                            .foregroundStyle(Clay.accentText)
                            .frame(width: 20, height: 20)
                            .background(Clay.claySoft, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.kind.title)
                                .font(Clay.bodyMedium)
                                .foregroundStyle(Clay.ink)
                            Text(detail(for: step.kind, options: step.options))
                                .font(Clay.caption)
                                .foregroundStyle(Clay.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Each copy is made from the original, in this order. The original isn't changed.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .padding(.top, Clay.space1)
            }
        }
        .clayCard()
        .accessibilityIdentifier("changes.summary")
    }

    private func detail(for kind: BuildStepKind, options: CleaningOptions) -> String {
        switch kind {
        case .provenance:
            let metadata = options.keepNonAIMetadata ? "ordinary metadata kept" : "all removable metadata stripped"
            let spaces = options.normalizeSpaces ? "unusual spaces replaced" : "spacing kept"
            return job.isPDF
                ? "\(metadata.prefix(1).uppercased() + metadata.dropFirst()); PDF images: \(AppPreferences.DeepImageMode(rawValue: options.deepImages)?.displayName.lowercased() ?? options.deepImages)."
                : "\(metadata.prefix(1).uppercased() + metadata.dropFirst()); \(spaces)."
        case .wordTraces:
            guard let traces = options.wordTraces else { return "" }
            var text = "Session IDs: \(traces.rsids.displayName.lowercased()); dates: \(traces.dates.displayName.lowercased())"
            if traces.resetArchiveDates { text += "; ZIP dates reset" }
            return text + "."
        case .properties:
            let edits = options.metadataEdits ?? [:]
            let labels = edits.keys.sorted().map { MetadataLabels.label(for: $0) }
            let removed = edits.values.filter(\.isEmpty).count
            var text = labels.joined(separator: ", ")
            if removed > 0 { text += " (\(removed) removed)" }
            return text + "."
        case .checking:
            return ""
        }
    }
}

enum MetadataLabels {
    static func label(for id: String) -> String {
        [
            "author": "Author", "title": "Title", "subject": "Subject", "description": "Description",
            "keywords": "Keywords", "lastModifiedBy": "Last saved by", "copyright": "Copyright",
        ][id] ?? id
    }
}
