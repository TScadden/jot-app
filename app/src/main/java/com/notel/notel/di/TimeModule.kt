package com.notel.notel.di

import com.notel.notel.util.DefaultTimeProvider
import com.notel.notel.util.TimeProvider
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class TimeModule {

    @Binds
    @Singleton
    abstract fun bindTimeProvider(impl: DefaultTimeProvider): TimeProvider
}
