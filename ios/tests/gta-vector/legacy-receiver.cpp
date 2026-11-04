#include "fixtures/aa13-VectorPacket.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>

static bool accepts(const char *path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw "Cannot read receiver fixture";
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)), {});
    return vectorPacketValid(data.data(), data.size());
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    try {
        if (accepts(argv[1]) || !accepts(argv[2]) || !accepts(argv[3])) return 1;
        std::cout << "AA13 production receiver: rich packet rejected; compatible and baseline packets accepted\n";
        return 0;
    } catch (...) {
        return 2;
    }
}
