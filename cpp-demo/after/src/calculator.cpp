#include "calculator.h"

#include <stdexcept>

double Calculator::compute(const std::string& op, double a, double b) {
    if (op == "add") return a + b;
    if (op == "sub") return a - b;
    if (op == "mul") return a * b;
    if (op == "div") {
        if (b == 0.0) throw std::invalid_argument("division by zero");
        return a / b;
    }
    throw std::invalid_argument("unknown operation: " + op);
}
