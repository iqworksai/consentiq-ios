import Foundation

struct SheetSelection: Equatable {
    private(set) var values: ConsentState

    init(consent: ConsentState, categories: [CategoryInfo]) {
        var values = consent
        for category in categories where category.enabled {
            if values[category.code] == nil {
                values[category.code] = category.defaultState
            }
            if category.isRequired {
                values[category.code] = true
            }
        }
        self.values = values.forcingNecessary()
    }

    func isOn(_ category: CategoryInfo) -> Bool {
        category.isRequired || values[category.code] == true
    }

    mutating func set(_ code: String, _ isOn: Bool) {
        values[code] = isOn
        values = values.forcingNecessary()
    }
}
