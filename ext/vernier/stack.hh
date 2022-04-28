#pragma once

#include "ruby/debug.h"

#include <iostream>
#include <vector>
#include <memory>
#include <algorithm>

struct Frame {
    VALUE frame;
    int line;

    VALUE full_label() const {
        return rb_profile_frame_full_label(frame);
    }

    VALUE absolute_path() const {
        return rb_profile_frame_absolute_path(frame);
    }

    VALUE path() const {
        return rb_profile_frame_path(frame);
    }

    VALUE file() const {
        VALUE file = absolute_path();
        return NIL_P(file) ? path() : file;
    }

    VALUE first_lineno() const {
        return rb_profile_frame_first_lineno(frame);
    }
};

bool operator==(const Frame& lhs, const Frame& rhs) noexcept {
    return lhs.frame == rhs.frame && lhs.line == rhs.line;
}

template<>
struct std::hash<Frame>
{
    std::size_t operator()(Frame const& s) const noexcept
    {
        return s.frame ^ s.line;
    }
};

struct Stack {
    std::unique_ptr<VALUE[]> frames;
    std::unique_ptr<int[]> lines;
    int _size = 0;

    int size() const {
        return _size;
    }

    Stack(const VALUE *_frames, const int *_lines, int size) :
        _size(size),
        frames(std::make_unique<VALUE[]>(size)),
        lines(std::make_unique<int[]>(size))
    {
        std::copy_n(_frames, size, &frames[0]);
        std::copy_n(_lines, size, &lines[0]);
    }

    Stack(const Stack &s) :
        _size(s.size()),
        frames(std::make_unique<VALUE[]>(s.size())),
        lines(std::make_unique<int[]>(s.size()))
    {
        std::copy_n(&s.frames[0], s.size(), &frames[0]);
        std::copy_n(&s.lines[0], s.size(), &lines[0]);
    }

    Frame frame(int i) const {
        if (i >= size()) throw std::out_of_range("nope");
        return Frame{frames[i], lines[i]};
    }
};

bool operator==(const Stack& lhs, const Stack& rhs) noexcept {
    return lhs.size() == rhs.size() &&
        std::equal(&lhs.frames[0], &lhs.frames[lhs.size()], &rhs.frames[0]) &&
        std::equal(&lhs.lines[0], &lhs.lines[lhs.size()], &rhs.lines[0]);
}

// https://xoshiro.di.unimi.it/splitmix64.c
// https://nullprogram.com/blog/2018/07/31/
uint64_t
hash64(uint64_t x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

template<>
struct std::hash<Stack>
{
    std::size_t operator()(Stack const& s) const noexcept
    {
        size_t hash = 0;
        for (int i = 0; i < s.size(); i++) {
            VALUE frame = s.frames[i];
            hash ^= frame;
            hash = hash64(hash);
        }
        return hash;
    }
};


std::ostream& operator<<(std::ostream& os, const Frame& frame)
{
    VALUE label = frame.full_label();
    VALUE file = frame.absolute_path();
    const char *file_cstr = NIL_P(file) ? "" : StringValueCStr(file);
    os << file_cstr << ":" << frame.line << ":in `" << StringValueCStr(label) << "'";
    return os;
}

std::ostream& operator<<(std::ostream& os, const Stack& stack)
{
    for (int i = 0; i < stack.size(); i++) {
        Frame frame = stack.frame(i);
        os << frame << "\n";
    }

    return os;
}

