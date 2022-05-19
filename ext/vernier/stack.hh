#pragma once

#include "ruby/debug.h"

#include <iostream>
#include <vector>
#include <memory>
#include <algorithm>

struct FrameInfo {
    static const char *label_cstr(VALUE frame) {
        VALUE label = rb_profile_frame_full_label(frame);
        return StringValueCStr(label);
    }

    static const char *file_cstr(VALUE frame) {
        VALUE file = rb_profile_frame_absolute_path(frame);
        if (NIL_P(file))
            file = rb_profile_frame_path(frame);
        if (NIL_P(file)) {
            return "";
        } else {
            return StringValueCStr(file);
        }
    }

    static int first_lineno_int(VALUE frame) {
        VALUE first_lineno = rb_profile_frame_first_lineno(frame);
        return FIX2INT(first_lineno);
    }

    FrameInfo(VALUE frame, int line) :
        label(label_cstr(frame)),
        file(file_cstr(frame)),
        //first_lineno(first_lineno_int(frame)),
        line(line) { }

    FrameInfo(std::string label, std::string file = "", int line = 0) :
        label(label),
        file(file),
        line(line) { }

    std::string label;
    std::string file;
    // int first_lineno;
    int line;
};

bool operator==(const FrameInfo& lhs, const FrameInfo& rhs) noexcept {
    return
        lhs.label == rhs.label &&
        lhs.file == rhs.file &&
        lhs.line == rhs.line;
}

template<>
struct std::hash<FrameInfo>
{
    std::size_t operator()(FrameInfo const& f) const noexcept
    {
        return
            std::hash<std::string>{}(f.label) ^
            std::hash<std::string>{}(f.file) ^
            f.line;
    }
};


struct Frame {
    VALUE frame;
    int line;

    FrameInfo info() const {
        return FrameInfo(frame, line);
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

struct BaseStack {
    virtual ~BaseStack() {};

	virtual int size() const = 0;
    virtual FrameInfo frame_info(int i) const = 0;
};

struct InfoStack : public BaseStack {
    std::vector<FrameInfo> frames;

    int size() const override {
        return frames.size();
    }

    InfoStack() {
    }

    InfoStack(const BaseStack &stack) {
        for (int i = 0; i < stack.size(); i++) {
            push_back(stack.frame_info(i));
        }
    }

    void push_back(FrameInfo i) {
        frames.push_back(i);
    }

    FrameInfo frame_info(int i) const override {
        if (i >= size()) throw std::out_of_range("nope");
        return frames[i];
    }
};

struct Stack : public BaseStack {
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

    FrameInfo frame_info(int i) const {
        return frame(i).info();
    }
};

bool operator==(const Stack& lhs, const Stack& rhs) noexcept {
    return lhs.size() == rhs.size() &&
        std::equal(&lhs.frames[0], &lhs.frames[lhs.size()], &rhs.frames[0]) &&
        std::equal(&lhs.lines[0], &lhs.lines[lhs.size()], &rhs.lines[0]);
}

bool operator==(const InfoStack& lhs, const InfoStack& rhs) noexcept {
    return lhs.size() == rhs.size() &&
        std::equal(lhs.frames.begin(), lhs.frames.end(), rhs.frames.begin());
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

template<>
struct std::hash<InfoStack>
{
    std::size_t operator()(InfoStack const& s) const noexcept
    {
        size_t hash = 0;
        for (int i = 0; i < s.size(); i++) {
            FrameInfo info = s.frame_info(i);
            hash ^= std::hash<FrameInfo>{}(info);
            hash = hash64(hash);
        }
        return hash;
    }
};

std::ostream& operator<<(std::ostream& os, const FrameInfo& info)
{
    os << info.file;
    if (info.line) {
        os << ":" << info.line;
    }
    os << ":in `" << info.label << "'";
    return os;
}


std::ostream& operator<<(std::ostream& os, const Frame& frame)
{
    return os << frame.info();
}

std::ostream& operator<<(std::ostream& os, const BaseStack& stack)
{
    for (int i = 0; i < stack.size(); i++) {
        FrameInfo info = stack.frame_info(i);
        os << info << "\n";
    }

    return os;
}

