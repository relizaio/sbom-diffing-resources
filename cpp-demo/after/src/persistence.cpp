// persistence.cpp
//
// DEMO INJECTION — illustrates a foreign source file landing in a build.
// Benign by design; the only "supply-chain" property we want to exhibit is
// its sudden appearance in the SBOM with no upstream package provenance.
//
// In a real pipeline, continuous SBOM diffing would catch this on the
// pre-merge check and require a human reason for the file before promotion.

#include <fstream>
#include <string>

namespace persistence {

// Looks innocuous; does nothing the calculator needs.
void note(const std::string& msg) {
    std::ofstream out(".calc-cli.log", std::ios::app);
    out << msg << '\n';
}

}  // namespace persistence
