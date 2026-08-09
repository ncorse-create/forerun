import Foundation
import SwiftData

/// The schema, versioned from the first commit.
///
/// There is exactly one version today and that is the point: the migration machinery exists
/// before it is needed, so adding a property in v1.1 is a new `VersionedSchema` plus a stage
/// rather than an emergency. `PlaybookTemplate` is deliberately **not** in here — playbooks are
/// Swift value types in code, so a wrong offset can be corrected in an app update without a
/// migration.
public enum SchemaV1: VersionedSchema {
    /// Bumped as the schema was still being drafted pre-release: `PrepStep.calendarBlockIdentifier`,
    /// `PrepPlan.droppedToCapCount` and `StepOutcome.stepID` were all added after the first
    /// commit. All three are optional or defaulted, so SwiftData's implicit lightweight migration
    /// covers them — but the identifier must not claim the models are unchanged.
    ///
    /// **Once a build ships to anyone, this stops being acceptable** and the next change is a
    /// `SchemaV2` with a stage in `ForerunMigrationPlan`.
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 3, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            TrackedEvent.self,
            PrepPlan.self,
            PrepStep.self,
            ScratchpadItem.self,
            EventContact.self,
            StepOutcome.self,
            AppSettings.self
        ]
    }
}

/// One version, one stage list, no stages. When `SchemaV2` arrives, it goes here and the
/// container keeps working.
public enum ForerunMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

/// The only correct way to build the container.
///
/// A view calling `.modelContainer(for: TrackedEvent.self)` would build a *different* container
/// with SwiftData's defaults, which include CloudKit mirroring when an iCloud entitlement is
/// present. Mirroring plus `@Attribute(.unique)` traps at launch, so that mistake would not be
/// caught until a device build. Everything goes through here.
public enum ForerunStore {
    /// The one live container for this process.
    ///
    /// App Intents run *inside the app's process* — Siri launches the app to serve them — so an
    /// intent that called `container()` got a second `ModelContainer` over the same SQLite file.
    /// Two containers do not share a change-notification path, so the app's long-lived context
    /// kept its own stale copies of anything the intent wrote and could write them back on its
    /// next save. One shared instance removes the problem entirely.
    public static let shared: ModelContainer? = try? container()

    /// The live on-disk container. No CloudKit: `cloudKitDatabase: .none` is explicit rather
    /// than implied, because adding an iCloud entitlement later would otherwise silently switch
    /// mirroring on and trap at launch against a schema with unique constraints.
    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Forerun",
            schema: Schema(SchemaV1.models),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(SchemaV1.models),
            migrationPlan: ForerunMigrationPlan.self,
            configurations: configuration
        )
    }
}
