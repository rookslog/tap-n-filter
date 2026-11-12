import Foundation

@main
struct ContractMain {
    static func main() async {
        var failures = 0
        for contract in ModelContract.all {
            do {
                try await contract.run()
                print("PASS \(contract.name)")
            } catch {
                failures += 1
                print("FAIL \(contract.name): \(error)")
            }
        }
        print("SoundModel contracts: \(ModelContract.all.count) scenarios, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
