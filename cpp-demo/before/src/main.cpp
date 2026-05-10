#include <CLI/CLI.hpp>
#include <fmt/core.h>
#include <string>

#include "calculator.h"
#include "utils.h"

int main(int argc, char** argv) {
    CLI::App app{"calc-cli — tiny calculator demo"};

    std::string op = "add";
    double a = 0.0;
    double b = 0.0;
    app.add_option("--op", op, "Operation: add, sub, mul, div")->required();
    app.add_option("--a", a, "First operand")->required();
    app.add_option("--b", b, "Second operand")->required();
    CLI11_PARSE(app, argc, argv);

    Calculator calc;
    double result = calc.compute(op, a, b);
    fmt::print("{} {} {} = {}\n", a, op, b, format_result(result));
    return 0;
}
