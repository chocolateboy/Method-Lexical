#include "EXTERN.h"
#include "perl.h"

/*
 * chocolateboy 2009-02-08
 *
 * for binary compatibility (see perlapi.h), XS modules perform a function call to
 * access each and every interpreter variable. So, for instance, an innocuous-looking
 * reference to PL_op becomes:
 *
 *     (*Perl_Iop_ptr(my_perl))
 *
 * This (obviously) impacts performance. Internally, PL_op is accessed as:
 *
 *     my_perl->Iop
 *
 * (in threaded/multiplicity builds (see intrpvar.h)), which is significantly faster.
 *
 * defining PERL_CORE gets us the fast version, at the expense of a future maintenance release
 * possibly breaking things: http://www.xray.mpe.mpg.de/mailing-lists/perl5-porters/2008-04/msg00171.html
 *
 * Rather than globally defining PERL_CORE, which pokes its fingers into various headers, exposing
 * internals we'd rather not see, just define it for XSUB.h, which includes
 * perlapi.h, which imposes the speed limit.
 */

#define PERL_CORE
#include "XSUB.h"
#undef PERL_CORE

#define NEED_sv_2pv_flags
#include "ppport.h"

#include "hook_op_check.h"
#include "hook_op_annotation.h"
#include "mro.h"

#include <string.h> /* for strchr and strlen */
/* #define NDEBUG */
#include <assert.h>

#define METHOD_LEXICAL_INSTALLED "Method::Lexical"

#define METHOD_LEXICAL_ENABLED(table, svp)                                                        \
    ((PL_hints & 0x20000) &&                                                                      \
    (table = GvHV(PL_hintgv)) &&                                                                  \
    (svp = hv_fetch(table, METHOD_LEXICAL_INSTALLED, strlen(METHOD_LEXICAL_INSTALLED), FALSE)) && \
    *svp &&                                                                                       \
    SvOK(*svp) &&                                                                                 \
    SvROK(*svp) &&                                                                                \
    SvRV(*svp) &&                                                                                 \
    SvTYPE(SvRV(*svp)) == SVt_PVHV)

typedef struct MethodLexicalDataList {
    const HV *stash;
    U32 generation;
    const CV *cv;
    const SV * method;
    struct MethodLexicalDataList *next;
} MethodLexicalDataList;

typedef struct MethodLexicalData {
    HV *hv;
    MethodLexicalDataList *list;
    U32 dynamic;
} MethodLexicalData;

STATIC CV * method_lexical_hash_get(pTHX_ HV * const hv, SV * const key);
STATIC HV * method_lexical_get_fqname_stash(pTHX_ SV **method_sv_ptr, char **class_name_ptr);
STATIC HV * method_lexical_get_invocant_stash(pTHX_ SV * const invocant, char **class_name_ptr);
STATIC HV * method_lexical_get_super_stash(pTHX_ const char * const class_name, char **class_name_ptr);
STATIC MethodLexicalData * method_lexical_data_new(pTHX_ HV * const hv, const U32 dynamic);
STATIC OP * method_lexical_check_method_dynamic(pTHX_ OP * o);
STATIC OP * method_lexical_check_method(pTHX_ OP * o, void *user_data);
STATIC OP * method_lexical_check_method_static(pTHX_ OP * o);
STATIC OP * method_lexical_method_dynamic(pTHX);
STATIC OP * method_lexical_method_static(pTHX);
STATIC void method_lexical_data_free(pTHX_ void *data);
STATIC void method_lexical_data_list_free(pTHX_ void *vp);
STATIC void method_lexical_enter();
STATIC void method_lexical_leave();

STATIC MethodLexicalDataList * method_lexical_data_list_new(
    pTHX_
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
);

STATIC SV *method_lexical_cache_get(
    pTHX_
    MethodLexicalData *data,
    const HV * const stash,
    const SV * const method,
    U32 * const retval
);

STATIC void method_lexical_cache_set(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
);

STATIC SV * method_lexical_method_common(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const char * const class_name,
    const SV * const method
);

STATIC void method_lexical_cache_remove(
    pTHX_
    MethodLexicalData * const data,
    MethodLexicalDataList *prev,
    MethodLexicalDataList *head
);

STATIC hook_op_check_id method_lexical_check_method_id = 0;
STATIC OPAnnotationGroup METHOD_LEXICAL_ANNOTATIONS;
STATIC U32 METHOD_LEXICAL_COMPILING = 0;
STATIC U32 METHOD_LEXICAL_DEBUG = 0;

STATIC MethodLexicalData * method_lexical_data_new(pTHX_ HV * const hv, const U32 dynamic) {
    MethodLexicalData *data;

    Newx(data, 1, MethodLexicalData);

    if (!data) {
        croak("couldn't allocate annotation data");
    }

    data->hv = (HV * const)SvREFCNT_inc(hv); /* this is needed to prevent the hash being garbage-collected */
    data->dynamic = dynamic;
    data->list = NULL;

    return data;
}

STATIC void method_lexical_data_free(pTHX_ void *vp) {
    MethodLexicalData *data = (MethodLexicalData *)vp;

    if (data->list) {
        method_lexical_data_list_free(aTHX_ data->list);
    }

    SvREFCNT_dec(data->hv);
    Safefree(data);
}

STATIC MethodLexicalDataList * method_lexical_data_list_new(
    pTHX_
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
) {
    MethodLexicalDataList *list;
    Newx(list, 1, MethodLexicalDataList);

    if (!list) {
        croak("couldn't allocate annotation data list");
    }

    /* the refcount increments are needed to prevent the values being garbage-collected */
    list->stash = (HV *const)SvREFCNT_inc(stash);
    list->method = method ? (SV * const)SvREFCNT_inc(method) : method;
    list->generation = generation;
    list->cv = (CV * const)SvREFCNT_inc(cv);
    list->next = NULL;

    return list;
}

STATIC void method_lexical_data_list_free(pTHX_ void *vp) {
    MethodLexicalDataList *list = (MethodLexicalDataList *)vp;
    MethodLexicalDataList *temp;

    while (list) {
        temp = list->next;
        SvREFCNT_dec(list->stash);
        SvREFCNT_dec(list->method);
        SvREFCNT_dec(list->cv);
        Safefree(list);
        list = temp;
    }
}

/*
 * the method name may be qualified e.g. 
 *
 *     $self->Foo::Bar::Baz($quux);
 *
 * in this case, we can turn it into a subroutine call:
 *
 *     Foo::Bar::Baz($self, $quux)
 *
 * XXX: Perl_ck_method does not turn fully-qualified names into OP_METHOD_NAMED
 * XXX: Perl_ck_method does not normalize fully-qualified names i.e. need to s/'/::/g
 */

STATIC OP * method_lexical_check_method(pTHX_ OP * o, void * user_data) {
     PERL_UNUSED_VAR(user_data);

    /*
     * Perl_ck_method can upgrade an OP_METHOD to an OP_METHOD_NAMED (perly.y
     * channels all method calls through newUNOP(OP_METHOD)),
     * so we need to assign the right method ppaddr, or bail if the OP's no
     * longer a method (i.e. another module has changed it)
     */

    if (o->op_type == OP_METHOD_NAMED) {
        return method_lexical_check_method_static(aTHX_ o);
    } else if (o->op_type == OP_METHOD) {
        return method_lexical_check_method_dynamic(aTHX_ o);
    }

    return o;
}

STATIC OP * method_lexical_check_method_dynamic(pTHX_ OP * o) {
    HV * table;
    SV ** svp;

    /* if there are bindings for the currently-compiling scope in $^H{METHOD_LEXICAL_INSTALLED} */
    if (METHOD_LEXICAL_ENABLED(table, svp)) {
        MethodLexicalData *data;
        HV *installed = (HV *)SvRV(*svp);

        data = method_lexical_data_new(aTHX_ installed, TRUE);
        (void)op_annotation_new(METHOD_LEXICAL_ANNOTATIONS, o, (void *)data, method_lexical_data_free);

        o->op_ppaddr = method_lexical_method_dynamic;
    }

    return o;
}

STATIC OP * method_lexical_check_method_static(pTHX_ OP * o) {
    HV * table;
    SV ** svp;

    /* if there are bindings for the currently-compiling scope in $^H{METHOD_LEXICAL_INSTALLED} */
    if (METHOD_LEXICAL_ENABLED(table, svp)) {
        STRLEN fqnamelen, namelen;
        HE *entry;
        HV *installed = (HV *)SvRV(*svp);
        UV count = 0;
        SV *method = cSVOPo->op_sv;
        const char *fqname, *name = SvPV_const(method, namelen);

        assert(!(strchr(name, ':') && strchr(name, '\'')));

        hv_iterinit(installed);

        while ((entry = hv_iternext(installed))) {
            const char *rcolon;

            fqname = HePV(entry, fqnamelen);

            /*
             * There are 2 options:
             *
             * 1) count == 0: the name isn't in the hash: don't change the op_ppaddr
             * 2) count >  0: this *may* be a lexical method call - change the op_ppaddr
             */

            rcolon = strrchr(fqname, ':');

            /* WARN("comparing OP method (%*s) => fqname method (%s)", namelen, name, rcolon + 1); */
            if (strnEQ(name, rcolon + 1, namelen)) {
                ++count;
            }
        }

        if (count) {
            MethodLexicalData *data;

            data = method_lexical_data_new(aTHX_ installed, FALSE);
            (void)op_annotation_new(METHOD_LEXICAL_ANNOTATIONS, o, (void *)data, method_lexical_data_free);

            o->op_ppaddr = method_lexical_method_static;
        } /* else no lexical method of this name */
    }
        
    return o;
}

STATIC OP * method_lexical_method_dynamic(pTHX) {
    dSP;
    SV * cv;
    SV * method_sv = TOPs;

    if (SvROK(method_sv) && (cv = SvRV(method_sv)) && (SvTYPE(cv) == SVt_PVCV)) {
        SETs(cv);
        RETURN;
    } else {
        char *class_name;
        const OPAnnotation * annotation = op_annotation_get(METHOD_LEXICAL_ANNOTATIONS, PL_op);
        const HV * const stash = method_lexical_get_fqname_stash(aTHX_ &method_sv, &class_name);

        if (stash) {
            U32 cached;
            MethodLexicalData * data;
            data = (MethodLexicalData *)annotation->data;;
            cv = method_lexical_cache_get(aTHX_ data, stash, method_sv, &cached);

            if (!cached) {
                cv = method_lexical_method_common(aTHX_ data, stash, class_name, method_sv);
            }

            if (cv) {
                SETs(cv);
                RETURN;
            }
        }

        return CALL_FPTR(annotation->op_ppaddr)(aTHX);
    }
}

STATIC OP *method_lexical_method_static(pTHX) {
    dSP;
    char *class_name;
    SV * const invocant = *(PL_stack_base + TOPMARK + 1);
    const HV * const stash = method_lexical_get_invocant_stash(aTHX_ invocant, &class_name);
    const OPAnnotation * const annotation = op_annotation_get(METHOD_LEXICAL_ANNOTATIONS, PL_op);

    if (stash) {
        U32 cached;
        const SV * const method = cSVOP_sv;
        MethodLexicalData * const data = (MethodLexicalData *)annotation->data;
        SV *cv = method_lexical_cache_get(aTHX_ data, stash, method, &cached);

        if (!cached) {
            cv = method_lexical_method_common(aTHX_ data, stash, class_name, method);
        }

        if (cv) {
            XPUSHs(cv);
            RETURN;
        }
    }

    return CALL_FPTR(annotation->op_ppaddr)(aTHX);
}

STATIC SV * method_lexical_method_common(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const char * const class_name,
    const SV * const method
) {
    const char * name;
    SV *key;
    HV * const installed = data->hv;
    CV *cv = NULL;

    name = SvPVX(method);
    key = sv_2mortal(newSVpvf("%s::%s", class_name, name));
    cv = method_lexical_hash_get(aTHX_ installed, key);

    if (cv) {
        /* generation 0 means this private method is in the installed hash and so can never be invalidated */
        method_lexical_cache_set(aTHX_ data, stash, 0, method, cv);
    } else { /* try superclasses */
        AV *isa;
        U32 items, generation;
        SV **svp;

        generation = mro_get_pkg_gen(stash);
        isa = mro_get_linear_isa((HV *)stash); /* temporarily cast off constness */

        assert(isa);
        assert(SvTYPE(isa) == SVt_PVAV);

        items = AvFILLp(isa) + 1; /* add 1 (even though we're skipping self) to include the appended "UNIVERSAL" */
        svp = AvARRAY(isa) + 1;   /* skip self */

        while (items--) { /* always entered, if only for "UNIVERSAL" */
            SV *class_name_sv;
            char *class_name_pv;
            HV *isa_stash;

            if (items == 0) {
                class_name_sv = sv_2mortal(newSVpvn("UNIVERSAL", 9));
            } else {
                class_name_sv = *svp++;
            }

            key = sv_2mortal(newSVpvf("%s::%s", SvPVX(class_name_sv), name));
            assert(key);

            isa_stash = method_lexical_get_invocant_stash(aTHX_ class_name_sv, &class_name_pv);

            cv = method_lexical_hash_get(aTHX_ installed, key);

            if (cv) {
                method_lexical_cache_set(aTHX_ data, stash, generation, method, cv);
                break;
            }
        }

        if (!cv) {
            /* cache a "not found" marker: NULL */
            method_lexical_cache_set(aTHX_ data, stash, generation, method, NULL);
        }
    }

    return (SV *)cv;
}

STATIC HV *method_lexical_get_invocant_stash(pTHX_ SV * const invocant, char **class_name_ptr) {
    HV *stash = NULL;
    char *class_name = NULL;
    STRLEN packlen;

    SvGETMAGIC(invocant);

    if (!(invocant && SvOK(invocant))) {
        goto done;
    }

    if (SvROK(invocant)) { /* blessed reference */
        if (SvOBJECT(SvRV(invocant))) {
#ifdef HvNAME_HEK
            HEK *hek;

            if (
                (stash = SvSTASH(SvRV(invocant))) &&
                (hek = HvNAME_HEK(stash)) &&
                (class_name = HEK_KEY(hek))
            ) {
                goto done;
            }
#else
            if (
                ((stash = SvSTASH(SvRV(invocant)))) &&
                (class_name = HvNAME(stash))
            ) {
                goto done;
            }
#endif
        } /* unblessed reference */
    } else if ((class_name = SvPV(invocant, packlen))) { /* not a reference: try package name */
        const HE *const he = hv_fetch_ent(PL_stashcache, invocant, 0, 0);

        if (he) {
            stash = INT2PTR(HV *, SvIV(HeVAL(he)));
        } else if ((stash = gv_stashpvn(class_name, packlen, 0))) {
            SV *const ref = newSViv(PTR2IV(stash));
            (void) hv_store(PL_stashcache, class_name, packlen, ref, 0);
        } /* can't find a stash */
    }

    done:
        if (class_name_ptr) {
            *class_name_ptr = class_name;
        }

        return stash;
}

STATIC HV * method_lexical_get_super_stash(pTHX_ const char * const class_name, char **class_name_ptr) {
    SV * const invocant = sv_2mortal(newSVpv(class_name, 0));
    HV * stash = method_lexical_get_invocant_stash(aTHX_ invocant, NULL);

    if (stash) {
        const AV * const isa = mro_get_linear_isa((HV *)stash); /* temporarily cast off constness */

        if (isa && ((AvFILL(isa) + 1) > 1)) { /* at least two items: self and the superclass */
            SV * const * const svp = AvARRAY(isa) + 1; /* skip self */

            if (svp && *svp) {
                assert(SvOK(*svp));
                return method_lexical_get_invocant_stash(aTHX_ *svp, class_name_ptr);
            }
        }
    }

    return stash;
}

STATIC HV * method_lexical_get_fqname_stash(pTHX_ SV **method_sv_ptr, char **class_name_ptr) {
    HV *stash;
    const char *fqname;
    STRLEN offset, len;
    SV * invocant_sv, *normalized_sv = NULL, *fqmethod_sv = *method_sv_ptr;
    UV i;

    fqname = SvPV(*method_sv_ptr, len);

    /* 
     * kill two birds with one scan:
     *
     * 1) normalized_sv: normalize the fully-qualified name if it contains '\'' i.e. s/'/::/g
     * 2) offset: find the offset (in fqname) of the start of the unqualified method name
     */

    for (i = 0; i < len; ++i) {
        if (normalized_sv) {
            if (fqname[i] == '\'') {
                sv_catpvs(normalized_sv, "::");
                offset = i + 1;
            } else if ((fqname[i] == ':') && ((i + 1) < len) && (fqname[i + 1] == ':')) {
                sv_catpvs(normalized_sv, "::");
                offset = i + 2;
                ++i;
            } else {
                sv_catpvn(normalized_sv, fqname + i, 1);
            }
        } else {
            if (fqname[i] == '\'') {
                normalized_sv = sv_2mortal(newSVpv(fqname, i));
                sv_catpvs(normalized_sv, "::");
                offset = i + 1;
            } else if ((fqname[i] == ':') && ((i + 1) < len) && (fqname[i + 1] == ':')) {
                offset = i + 2;
                ++i;
            }
        }
    }

    /*
     * offset might be out of bounds if the name is mangled, which shouldn't happen
     * for a static name, but e.g.
     *
     *     my $name = 'foo:';
     *     $self->$name();
     *
     * so check that the offset (4 in this case) is sane
     */

    if (offset) {
        if (offset == len) {
            goto done;
        } else {
            STRLEN method_len = len - offset;
            char *class_name;
            STRLEN class_name_len;

            if (normalized_sv) {
                fqmethod_sv = normalized_sv;
            }

            *method_sv_ptr = sv_2mortal(newSVpvn(fqname + offset, len - offset));
            invocant_sv = sv_2mortal(newSVpvn(SvPVX(fqmethod_sv), SvCUR(fqmethod_sv) - (method_len + 2)));

            class_name = SvPV(invocant_sv, class_name_len);

            /*
             * we need to intercept SUPER before perl gets its hands on the method name
             * (in method_lexical_get_invocant_stash) because perl handles SUPER differently,
             * autovivifying stashes with a ::SUPER suffix - e.g. %Foo::SUPER:: - to create @Foo::SUPER::ISA
             * (see gv_get_super_pkg in gv.c). This causes lookups to succeed when we want them to fail (so that
             * we can fall back to perl).
             *
             * if valid, the class name either a) is "SUPER", b) ends with "::SUPER",
             * or c) doesn't contain "SUPER"
             *
             * if b), make sure it's prefixed with at least one character
             */

            if (strnEQ(class_name, "SUPER", 5)) {
                /*
                 * S_gv_get_super_pkg in perl 5.10's gv.c seems to think that (under 5.10 if USE_ITHREADS
                 * is not defined)
                 *
                 *     a) HvNAME_HEK(CopSTASH(PL_curcop)) should be used instead of CopSTASHPV(PL_curcop)
                 *        to figure out the name of the package in which the method invocation was compiled
                 *     b) CopSTASH(PL_curcop) may be NULL
                 *
                 * Either way, CopSTASHPV(cop) is defined as:
                 *
                 *     (CopSTASH(cop) ? HvNAME_get(CopSTASH(cop)) : NULL)
                 *
                 * and so may be NULL. 
                 *
                 * We have two choices. Either we can assert(CopSTASH(cop)) to figure out how, where
                 * and why a COP might *not* have a stash. Or we can give up and yield to pp_method and
                 * let perl figure out the whys and wherefores of its hackery.
                 *
                 * For now, do the former and hope an assertion fails in testing or in the wild.
                 */
                assert(PL_curcop);
                assert(CopSTASH(PL_curcop));
                return method_lexical_get_super_stash(aTHX_ CopSTASHPV(PL_curcop), class_name_ptr);
            } else if ((class_name_len > 7) && strnEQ(class_name + (class_name_len - 7), "::SUPER", 7)) {
                class_name[(class_name_len - 7)] = '\0';
                return method_lexical_get_super_stash(aTHX_ class_name, class_name_ptr);
            }
        }
    }

    /* unqualified method name: don't change the method SV */
    invocant_sv = *(PL_stack_base + TOPMARK + 1);
    stash = method_lexical_get_invocant_stash(aTHX_ invocant_sv, class_name_ptr);

    done:
        return stash;
}

STATIC void method_lexical_cache_set(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
) {
    MethodLexicalDataList *list;

    list = method_lexical_data_list_new(aTHX_ stash, generation, method, cv);

    if (data->list) {
        list->next = data->list;
    }

    data->list = list;
}

STATIC void method_lexical_cache_remove(
    pTHX_
    MethodLexicalData * const data,
    MethodLexicalDataList *prev,
    MethodLexicalDataList *head
) {
    if (prev) { /* not first */
        prev->next = head->next;
    } else if (head->next) { /* first */
        data->list = head->next;
    } else { /* only */
        data->list = NULL;
    }

    head->next = NULL;

    method_lexical_data_list_free(aTHX_ head);
}

STATIC SV *method_lexical_cache_get(
    pTHX_
    MethodLexicalData *data,
    const HV * const stash,
    const SV * const method,
    U32 * const retval
) {
    const CV *cv = NULL;
    *retval = FALSE;

    if (data->list) {
        MethodLexicalDataList *head, *prev = NULL;

        if (data->dynamic) {
            for (head = data->list; head; prev = head, head = head->next) {
                if ((stash == head->stash) && sv_eq((SV *)method, (SV *)head->method)) { /* cast off constness */
                    if (head->generation) {
                        U32 generation = mro_get_pkg_gen(stash);

                        /* fresh: cv may be NULL, indicating (still) not found */
                        if (head->generation == generation) {
                            cv = head->cv;
                            *retval = TRUE;
                            break;
                        } else { /* stale: remove from list */
                            method_lexical_cache_remove(aTHX_ data, prev, head);
                            break;
                        }
                    } else {
                        cv = head->cv;
                        *retval = TRUE;
                        break;
                    }
                }
            }
        } else {
            for (head = data->list; head; prev = head, head = head->next) {
                if (stash == head->stash) {
                    if (head->generation) {
                        U32 generation = mro_get_pkg_gen(stash);

                        /* fresh: cv may be NULL, indicating (still) not found */
                        if (head->generation == generation) {
                            cv = head->cv;
                            *retval = TRUE;
                            break;
                        } else { /* stale: remove from list */
                            method_lexical_cache_remove(aTHX_ data, prev, head);
                            break;
                        }
                    } else {
                        cv = head->cv;
                        *retval = TRUE;
                        break;
                    }
                }
            }
        }
    }

    return (SV *)cv;
}

STATIC CV *method_lexical_hash_get(pTHX_ HV * const hv, SV * const key) {
    HE *he;

    he = hv_fetch_ent(hv, key, FALSE, 0); /* don't create an undef value if it doesn't exist */

    if (he) {
        const SV * const rv = HeVAL(he);
        return (CV *)SvRV(rv);
    }

    return NULL;
}

STATIC void method_lexical_enter() {
    if (METHOD_LEXICAL_COMPILING != 0) {
        croak("method_lexical: scope overflow");
    } else {
        METHOD_LEXICAL_COMPILING = 1;
        method_lexical_check_method_id = hook_op_check(OP_METHOD, method_lexical_check_method, NULL);
    }
}

STATIC void method_lexical_leave() {
    if (METHOD_LEXICAL_COMPILING != 1) {
        croak("method_lexical: scope underflow");
    } else {
        METHOD_LEXICAL_COMPILING = 0;
        hook_op_check_remove(OP_METHOD, method_lexical_check_method_id);
    }
}

MODULE = Method::Lexical                PACKAGE = Method::Lexical

BOOT:
    if (PerlEnv_getenv("METHOD_LEXICAL_DEBUG")) {
        METHOD_LEXICAL_DEBUG = 1;
    }

    METHOD_LEXICAL_ANNOTATIONS = op_annotation_group_new();

void
END()
    CODE:
        if (METHOD_LEXICAL_ANNOTATIONS) { /* make sure it was initialised */
            op_annotation_group_free(aTHX_ METHOD_LEXICAL_ANNOTATIONS);
        }

SV *
xs_get_debug()
    PROTOTYPE:
    CODE:
        RETVAL = newSViv(METHOD_LEXICAL_DEBUG);
    OUTPUT:
        RETVAL

void
xs_set_debug(SV * dbg)
    PROTOTYPE:$
    CODE:
        METHOD_LEXICAL_DEBUG = SvIV(dbg);

char *
xs_signature()
    PROTOTYPE:
    CODE:
        RETVAL = METHOD_LEXICAL_INSTALLED;
    OUTPUT:
        RETVAL

void
xs_enter()
    PROTOTYPE:
    CODE:
        method_lexical_enter();

void
xs_leave()
    PROTOTYPE:
    CODE:
        method_lexical_leave();
