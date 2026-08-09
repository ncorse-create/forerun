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
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

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

public enum ForerunStore {
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
