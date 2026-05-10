#include "utils.h"

#include <cmath>
#include <sstream>

std::string format_result(double value) {
    std::ostringstream oss;
    if (std::floor(value) == value) {
        oss << static_cast<long long>(value);
    } else {
        oss << value;
    }
    return oss.str();
}
